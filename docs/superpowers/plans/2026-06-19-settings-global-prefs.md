# Settings → Global App Preferences (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the Settings screen into a focused global app-preferences screen (recording defaults, appearance, permissions, default save location, shortcuts reference, about), removing the duplicated per-clip frame-styling controls and the dev Alert demo.

**Architecture:** A new `GlobalPreferences` store/controller (mirrors `RecordingSettingsStore`) persists `defaultSaveLocation`. `SettingsScreen` becomes a self-contained `ConsumerStatefulWidget` reading global providers. The default save location pre-fills the export Save dialog and is the recording auto-save directory. The recording-bar gear is the single entry point; the editor's frame-settings button is removed.

**Tech Stack:** Flutter, flutter_riverpod (StateNotifierProvider), file_selector (`getSaveLocation` / `getDirectoryPath`), package_info_plus (new), url_launcher, the `AppPalette` theme extension.

**Spec:** `docs/superpowers/specs/2026-06-19-settings-global-prefs-design.md`

---

## File Structure

**New:**
- `packages/screen_recorder/lib/state/global_preferences_store.dart` — `GlobalPreferences` model + `GlobalPreferencesStore` (JSON sidecar).
- `packages/screen_recorder/lib/state/global_preferences_controller.dart` — controller + providers.
- `packages/screen_recorder/lib/services/save_directory.dart` — pure `resolveSaveDirectory(...)` helper.
- `packages/screen_recorder/lib/ui/widgets/permission_status_row.dart` — shared `PermissionStatusRow` (extracted from onboarding).
- Tests: `test/state/global_preferences_store_test.dart`, `test/state/global_preferences_controller_test.dart`, `test/services/save_directory_test.dart`, `test/services/file_saver_initial_dir_test.dart`, `test/ui/widgets/permission_status_row_test.dart`, `test/ui/screens/settings_screen_test.dart`.

**Modified:**
- `packages/screen_recorder/lib/main.dart` — load + override the new providers.
- `packages/screen_recorder/lib/state/recording_state.dart` — `startRecording` takes `defaultSaveLocation`; use `resolveSaveDirectory`.
- `packages/screen_recorder/lib/state/recording_action_router.dart` — pass `defaultSaveLocation` into `startRecording`.
- `packages/screen_recorder/lib/services/destination_handlers.dart` — `FileSaver` takes `initialDirectory`.
- `packages/screen_recorder/lib/ui/screens/playback_screen.dart` — pass `initialDirectory` to `FileSaver`; remove `_openFrameSettings` + its toolbar button.
- `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart` — gear → `const SettingsScreen()`; remove `_barFrame`.
- `packages/screen_recorder/lib/ui/screens/onboarding/pages/permissions_page.dart` — use shared `PermissionStatusRow`.
- `packages/screen_recorder/lib/ui/screens/settings_screen.dart` — full rewrite.
- `packages/screen_recorder/pubspec.yaml` — add `package_info_plus`.

---

### Task 1: `GlobalPreferences` store

**Files:**
- Create: `packages/screen_recorder/lib/state/global_preferences_store.dart`
- Test: `packages/screen_recorder/test/state/global_preferences_store_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/global_preferences_store_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:screen_recorder/state/global_preferences_store.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('globalprefs_test'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String path() => p.join(tmp.path, 'global_preferences.json');

  test('load() on a missing file returns defaults (null save location)', () async {
    final store = GlobalPreferencesStore(path: path());
    final loaded = await store.load();
    expect(loaded.defaultSaveLocation, isNull);
  });

  test('save() then load() round-trips the save location', () async {
    final store = GlobalPreferencesStore(path: path());
    await store.save(const GlobalPreferences(defaultSaveLocation: '/Users/me/Movies'));
    final loaded = await store.load();
    expect(loaded.defaultSaveLocation, '/Users/me/Movies');
  });

  test('saving null clears the save location', () async {
    final store = GlobalPreferencesStore(path: path());
    await store.save(const GlobalPreferences(defaultSaveLocation: '/x'));
    await store.save(const GlobalPreferences(defaultSaveLocation: null));
    expect((await store.load()).defaultSaveLocation, isNull);
  });

  test('malformed JSON falls back to defaults', () async {
    File(path()).writeAsStringSync('{ not json');
    final store = GlobalPreferencesStore(path: path());
    expect((await store.load()).defaultSaveLocation, isNull);
  });

  test('copyWith with clearSaveLocation:true nulls the field', () {
    const a = GlobalPreferences(defaultSaveLocation: '/x');
    expect(a.copyWith(clearSaveLocation: true).defaultSaveLocation, isNull);
    expect(a.copyWith().defaultSaveLocation, '/x');
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/state/global_preferences_store_test.dart`
Expected: FAIL — `global_preferences_store.dart` / `GlobalPreferences` not found.

- [ ] **Step 3: Write the implementation**

```dart
// packages/screen_recorder/lib/state/global_preferences_store.dart
import 'dart:convert';
import 'dart:io';

import 'package:slipreel_engine/utils/app_logger.dart';

/// Global, app-wide preferences (not per-project). Grows over time.
class GlobalPreferences {
  const GlobalPreferences({this.defaultSaveLocation});

  /// Absolute folder path used as the default recording/export destination.
  /// `null` means "ask each time / use the OS Documents directory".
  final String? defaultSaveLocation;

  GlobalPreferences copyWith({
    String? defaultSaveLocation,
    bool clearSaveLocation = false,
  }) =>
      GlobalPreferences(
        defaultSaveLocation:
            clearSaveLocation ? null : (defaultSaveLocation ?? this.defaultSaveLocation),
      );

  Map<String, dynamic> toJson() => {
        if (defaultSaveLocation != null) 'defaultSaveLocation': defaultSaveLocation,
      };

  static const defaults = GlobalPreferences();

  static GlobalPreferences fromJson(Map<String, dynamic> json) {
    final raw = json['defaultSaveLocation'];
    return GlobalPreferences(
      defaultSaveLocation: raw is String && raw.isNotEmpty ? raw : null,
    );
  }
}

/// JSON sidecar under getApplicationSupportDirectory(). Mirrors
/// [RecordingSettingsStore].
class GlobalPreferencesStore {
  GlobalPreferencesStore({required this.path});
  final String path;

  Future<GlobalPreferences> load() async {
    try {
      final file = File(path);
      if (!file.existsSync()) return GlobalPreferences.defaults;
      final raw = await file.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return GlobalPreferences.fromJson(json);
    } catch (e, st) {
      AppLogger.platform.w('GlobalPreferencesStore.load failed; falling back',
          error: e, stackTrace: st);
      return GlobalPreferences.defaults;
    }
  }

  Future<void> save(GlobalPreferences prefs) async {
    final file = File(path);
    await file.create(recursive: true);
    await file.writeAsString(jsonEncode(prefs.toJson()));
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/state/global_preferences_store_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/global_preferences_store.dart \
        packages/screen_recorder/test/state/global_preferences_store_test.dart
git commit -m "feat(settings): GlobalPreferences store with defaultSaveLocation (#2)"
```

---

### Task 2: `GlobalPreferences` controller + providers + main.dart wiring

**Files:**
- Create: `packages/screen_recorder/lib/state/global_preferences_controller.dart`
- Test: `packages/screen_recorder/test/state/global_preferences_controller_test.dart`
- Modify: `packages/screen_recorder/lib/main.dart` (init ~`:138-144`, overrides ~`:169-173`)

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/global_preferences_controller_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:screen_recorder/state/global_preferences_controller.dart';
import 'package:screen_recorder/state/global_preferences_store.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('globalprefs_ctrl'));
  tearDown(() => tmp.deleteSync(recursive: true));

  GlobalPreferencesController make() => GlobalPreferencesController(
        store: GlobalPreferencesStore(path: p.join(tmp.path, 'g.json')),
        initial: GlobalPreferences.defaults,
      );

  test('setDefaultSaveLocation updates state and persists', () async {
    final c = make();
    await c.setDefaultSaveLocation('/Users/me/Clips');
    expect(c.state.defaultSaveLocation, '/Users/me/Clips');
    expect(await c.store.load(), isA<GlobalPreferences>()
        .having((g) => g.defaultSaveLocation, 'saved', '/Users/me/Clips'));
  });

  test('setDefaultSaveLocation(null) clears it', () async {
    final c = make();
    await c.setDefaultSaveLocation('/x');
    await c.setDefaultSaveLocation(null);
    expect(c.state.defaultSaveLocation, isNull);
    expect((await c.store.load()).defaultSaveLocation, isNull);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/state/global_preferences_controller_test.dart`
Expected: FAIL — `global_preferences_controller.dart` not found.

- [ ] **Step 3: Write the implementation**

```dart
// packages/screen_recorder/lib/state/global_preferences_controller.dart
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
}

final globalPreferencesStoreProvider = Provider<GlobalPreferencesStore>(
  (ref) => throw UnimplementedError('Override globalPreferencesStoreProvider in main()'),
);

final globalPreferencesControllerProvider =
    StateNotifierProvider<GlobalPreferencesController, GlobalPreferences>(
  (ref) => throw UnimplementedError('Override globalPreferencesControllerProvider in main()'),
);
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/state/global_preferences_controller_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Wire into `main.dart`**

After the recording-settings init block (`packages/screen_recorder/lib/main.dart` ~`:144`), add:

```dart
  final globalPreferencesStore = GlobalPreferencesStore(
    path: p.join(
      (await getApplicationSupportDirectory()).path,
      'global_preferences.json',
    ),
  );
  final initialGlobalPreferences = await globalPreferencesStore.load();
```

In the `ProviderScope.overrides` list (after the `recordingSettingsControllerProvider` override, ~`:173`), add:

```dart
      globalPreferencesStoreProvider.overrideWithValue(globalPreferencesStore),
      globalPreferencesControllerProvider.overrideWith((ref) =>
          GlobalPreferencesController(
              store: globalPreferencesStore,
              initial: initialGlobalPreferences)),
```

Add the import near the other `state/` imports in `main.dart`:

```dart
import 'state/global_preferences_controller.dart';
import 'state/global_preferences_store.dart';
```

- [ ] **Step 6: Verify it compiles**

Run: `cd packages/screen_recorder && flutter analyze lib/main.dart lib/state/global_preferences_controller.dart`
Expected: `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/state/global_preferences_controller.dart \
        packages/screen_recorder/test/state/global_preferences_controller_test.dart \
        packages/screen_recorder/lib/main.dart
git commit -m "feat(settings): GlobalPreferences controller + providers, wired in main (#2)"
```

---

### Task 3: Save-directory resolver + recording wiring

**Files:**
- Create: `packages/screen_recorder/lib/services/save_directory.dart`
- Test: `packages/screen_recorder/test/services/save_directory_test.dart`
- Modify: `packages/screen_recorder/lib/state/recording_state.dart` (~`:132` signature, ~`:190` usage)
- Modify: `packages/screen_recorder/lib/state/recording_action_router.dart` (~`:47`)

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/services/save_directory_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/services/save_directory.dart';

void main() {
  test('null default falls back to the documents path', () {
    final dir = resolveSaveDirectory(
      defaultSaveLocation: null,
      documentsPath: '/docs',
      exists: (_) => true,
    );
    expect(dir, '/docs');
  });

  test('an existing default folder is used', () {
    final dir = resolveSaveDirectory(
      defaultSaveLocation: '/Users/me/Clips',
      documentsPath: '/docs',
      exists: (path) => path == '/Users/me/Clips',
    );
    expect(dir, '/Users/me/Clips');
  });

  test('a configured-but-missing folder falls back to documents', () {
    final dir = resolveSaveDirectory(
      defaultSaveLocation: '/Users/me/Deleted',
      documentsPath: '/docs',
      exists: (_) => false,
    );
    expect(dir, '/docs');
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/services/save_directory_test.dart`
Expected: FAIL — `save_directory.dart` not found.

- [ ] **Step 3: Write the implementation**

```dart
// packages/screen_recorder/lib/services/save_directory.dart
import 'dart:io';

/// Resolves the directory new recordings/exports should default to.
///
/// Uses [defaultSaveLocation] when it is set AND the folder still exists;
/// otherwise falls back to [documentsPath]. [exists] is injectable for tests;
/// production passes a real filesystem check.
String resolveSaveDirectory({
  required String? defaultSaveLocation,
  required String documentsPath,
  bool Function(String path)? exists,
}) {
  final check = exists ?? (path) => Directory(path).existsSync();
  final pref = defaultSaveLocation;
  if (pref != null && pref.isNotEmpty && check(pref)) return pref;
  return documentsPath;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/services/save_directory_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Thread the default into recording**

In `packages/screen_recorder/lib/state/recording_state.dart`, add the import at the top:

```dart
import '../services/save_directory.dart';
```

Change the `startRecording` signature (~`:132`) to add a parameter:

```dart
  Future<void> startRecording({
    MicrophoneConfig? microphone,
    SystemAudioConfig? systemAudio,
    CameraConfig? camera,
    PermissionsSnapshot? permissions,
    Future<void> Function(PermissionKind kind)? onDenied,
    String? defaultSaveLocation,
  }) async {
```

Replace the output-path block (~`:190-192`):

```dart
      final docsDir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final outputPath = '${docsDir.path}/recording_$ts.mp4';
```

with:

```dart
      final docsDir = await getApplicationDocumentsDirectory();
      final saveDir = resolveSaveDirectory(
        defaultSaveLocation: defaultSaveLocation,
        documentsPath: docsDir.path,
      );
      final ts = DateTime.now().millisecondsSinceEpoch;
      final outputPath = '$saveDir/recording_$ts.mp4';
```

- [ ] **Step 6: Pass it from the router**

In `packages/screen_recorder/lib/state/recording_action_router.dart`, add the import:

```dart
import 'global_preferences_controller.dart';
```

Inside `doStart()`, before the `await controller.startRecording(` call (~`:47`), read the preference defensively (the provider throws until overridden in `main()`):

```dart
      String? defaultSaveLocation;
      try {
        defaultSaveLocation =
            _container.read(globalPreferencesControllerProvider).defaultSaveLocation;
      } catch (_) {}
```

and add the argument to the `startRecording(` call:

```dart
      await controller.startRecording(
        microphone: micConfig,
        systemAudio: sysAudioConfig,
        camera: cameraConfig,
        permissions: snapshot,
        defaultSaveLocation: defaultSaveLocation,
        onDenied: (kind) {
          if (!context.mounted) return Future.value();
          return PermissionDeniedSheet.show(context, kind);
        },
      );
```

- [ ] **Step 7: Verify it compiles**

Run: `cd packages/screen_recorder && flutter analyze lib/state/recording_state.dart lib/state/recording_action_router.dart lib/services/save_directory.dart`
Expected: `No issues found!`

- [ ] **Step 8: Commit**

```bash
git add packages/screen_recorder/lib/services/save_directory.dart \
        packages/screen_recorder/test/services/save_directory_test.dart \
        packages/screen_recorder/lib/state/recording_state.dart \
        packages/screen_recorder/lib/state/recording_action_router.dart
git commit -m "feat(settings): recordings honor the default save location (#2)"
```

---

### Task 4: Export Save dialog pre-fill (`FileSaver.initialDirectory`)

**Files:**
- Modify: `packages/screen_recorder/lib/services/destination_handlers.dart` (`FileSaver` ~`:82-122`)
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (~`:1803-1804`)
- Test: `packages/screen_recorder/test/services/file_saver_initial_dir_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/services/file_saver_initial_dir_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/services/destination_handlers.dart';

void main() {
  test('injected save dialog is used and returns its path', () async {
    String? seen;
    final saver = FileSaver(
      initialDirectory: '/Users/me/Clips',
      saveDialog: (name) async {
        seen = name;
        return '/Users/me/Clips/$name';
      },
    );
    final out = await saver.resolveOutputPath(suggestedFileName: 'clip.mp4');
    expect(seen, 'clip.mp4');
    expect(out, '/Users/me/Clips/clip.mp4');
  });

  test('initialDirectory is exposed for the default dialog to consume', () {
    final saver = FileSaver(initialDirectory: '/Users/me/Clips');
    expect(saver.initialDirectory, '/Users/me/Clips');
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/services/file_saver_initial_dir_test.dart`
Expected: FAIL — `FileSaver` has no `initialDirectory`.

- [ ] **Step 3: Add `initialDirectory` to `FileSaver`**

In `packages/screen_recorder/lib/services/destination_handlers.dart`, replace the `FileSaver` constructor + `_defaultSaveDialog` (`:83-108`) with:

```dart
class FileSaver implements DestinationHandler {
  /// Constructs a [FileSaver].
  ///
  /// [saveDialog] is injectable for testing. In production the default
  /// implementation opens the real system Save dialog via `file_selector`,
  /// pointed at [initialDirectory] when one is provided.
  FileSaver({
    Future<String?> Function(String suggestedName)? saveDialog,
    this.initialDirectory,
  }) : _saveDialog =
            saveDialog ?? ((name) => _defaultSaveDialog(name, initialDirectory));

  /// Folder the Save dialog opens at (the configured default save location),
  /// or null to let the OS pick.
  final String? initialDirectory;

  final Future<String?> Function(String suggestedName) _saveDialog;

  static Future<String?> _defaultSaveDialog(
      String suggestedName, String? initialDirectory) async {
    final ext = p.extension(suggestedName); // e.g. ".mp4"
    final XTypeGroup typeGroup;
    if (ext == '.gif') {
      typeGroup = const XTypeGroup(label: 'GIF', extensions: ['gif']);
    } else {
      typeGroup = const XTypeGroup(label: 'MP4 video', extensions: ['mp4']);
    }

    final location = await getSaveLocation(
      suggestedName: suggestedName,
      acceptedTypeGroups: [typeGroup],
      initialDirectory: initialDirectory,
    );
    return location?.path;
  }
```

(Leave `resolveOutputPath` and `deliver` unchanged.)

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/services/file_saver_initial_dir_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Pass the default into the export call site**

In `packages/screen_recorder/lib/ui/screens/playback_screen.dart`, this method already has `ref` in scope (it's a `ConsumerState`). Find the destination switch (~`:1803`):

```dart
    final DestinationHandler handler = switch (settings.destination) {
      ExportDestination.file => FileSaver(),
```

Replace the `FileSaver()` line with:

```dart
      ExportDestination.file => FileSaver(
          initialDirectory:
              ref.read(globalPreferencesControllerProvider).defaultSaveLocation,
        ),
```

Add the import near the other `state/` imports in `playback_screen.dart`:

```dart
import '../../state/global_preferences_controller.dart';
```

- [ ] **Step 6: Verify it compiles**

Run: `cd packages/screen_recorder && flutter analyze lib/services/destination_handlers.dart lib/ui/screens/playback_screen.dart`
Expected: `No issues found!`

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/services/destination_handlers.dart \
        packages/screen_recorder/test/services/file_saver_initial_dir_test.dart \
        packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat(settings): export Save dialog opens at the default save location (#2)"
```

---

### Task 5: Shared `PermissionStatusRow` widget

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/permission_status_row.dart`
- Test: `packages/screen_recorder/test/ui/widgets/permission_status_row_test.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/onboarding/pages/permissions_page.dart` (remove private `_PermissionRow`/`_RowAction`, use shared)

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/widgets/permission_status_row_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/permission_status_row.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('granted shows a check and no buttons', (tester) async {
    await tester.pumpWidget(_host(PermissionStatusRow(
      kind: PermissionKind.microphone,
      label: 'Microphone',
      subtitle: 'For voice.',
      status: PermissionStatus.granted,
      onGrant: () {},
      onOpenSettings: () {},
    )));
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.text('Grant'), findsNothing);
  });

  testWidgets('notDetermined shows Grant and fires onGrant', (tester) async {
    var granted = false;
    await tester.pumpWidget(_host(PermissionStatusRow(
      kind: PermissionKind.camera,
      label: 'Camera',
      subtitle: 'For webcam.',
      status: PermissionStatus.notDetermined,
      onGrant: () => granted = true,
      onOpenSettings: () {},
    )));
    await tester.tap(find.text('Grant'));
    expect(granted, isTrue);
  });

  testWidgets('denied shows Open System Settings and fires the callback',
      (tester) async {
    var opened = false;
    await tester.pumpWidget(_host(PermissionStatusRow(
      kind: PermissionKind.accessibility,
      label: 'Accessibility',
      subtitle: 'For clicks.',
      status: PermissionStatus.denied,
      onGrant: () {},
      onOpenSettings: () => opened = true,
    )));
    await tester.tap(find.text('Open System Settings'));
    expect(opened, isTrue);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/permission_status_row_test.dart`
Expected: FAIL — `permission_status_row.dart` not found.

- [ ] **Step 3: Create the shared widget**

```dart
// packages/screen_recorder/lib/ui/widgets/permission_status_row.dart
import 'package:flutter/material.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// A label + subtitle row with a status-driven action: a check when granted,
/// "Open System Settings" when denied/restricted, "Grant" otherwise. Shared by
/// first-run onboarding and the Settings permissions section.
class PermissionStatusRow extends StatelessWidget {
  const PermissionStatusRow({
    super.key,
    required this.kind,
    required this.label,
    required this.subtitle,
    required this.status,
    required this.onGrant,
    required this.onOpenSettings,
  });

  final PermissionKind kind;
  final String label;
  final String subtitle;
  final PermissionStatus status;
  final VoidCallback onGrant;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.titleMedium),
                Text(subtitle,
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: Colors.white60)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          _action(),
        ],
      ),
    );
  }

  Widget _action() {
    switch (status) {
      case PermissionStatus.granted:
        return const Icon(Icons.check_circle, color: Colors.greenAccent);
      case PermissionStatus.denied:
      case PermissionStatus.restricted:
        return OutlinedButton(
          onPressed: onOpenSettings,
          child: const Text('Open System Settings'),
        );
      case PermissionStatus.notDetermined:
      case PermissionStatus.unsupported:
        return FilledButton.tonal(
          onPressed: onGrant,
          child: const Text('Grant'),
        );
    }
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/permission_status_row_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Use the shared widget in onboarding**

In `packages/screen_recorder/lib/ui/screens/onboarding/pages/permissions_page.dart`:
- Add the import: `import 'package:screen_recorder/ui/widgets/permission_status_row.dart';`
- Replace the `_PermissionRow(` usage (`:48`) with `PermissionStatusRow(` (same named args — identical signature).
- Delete the now-unused private classes `_PermissionRow` (`:73-116`) and `_RowAction` (`:118-147`).

- [ ] **Step 6: Verify onboarding still passes**

Run: `cd packages/screen_recorder && flutter analyze lib/ui/screens/onboarding/pages/permissions_page.dart && flutter test test/ui/screens/onboarding/ 2>/dev/null || true`
Expected: `No issues found!` and any existing onboarding tests still pass.

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/permission_status_row.dart \
        packages/screen_recorder/test/ui/widgets/permission_status_row_test.dart \
        packages/screen_recorder/lib/ui/screens/onboarding/pages/permissions_page.dart
git commit -m "refactor(permissions): extract shared PermissionStatusRow (#2)"
```

---

### Task 6: Add `package_info_plus` dependency

**Files:**
- Modify: `packages/screen_recorder/pubspec.yaml`

- [ ] **Step 1: Add the dependency**

In `packages/screen_recorder/pubspec.yaml`, under `dependencies:`, add:

```yaml
  package_info_plus: ^8.0.0
```

- [ ] **Step 2: Resolve dependencies**

Run (repo root): `melos bootstrap` (this repo is melos-managed). If `melos` is unavailable, run `cd packages/screen_recorder && flutter pub get`.
Expected: resolves with `package_info_plus` added, no version conflicts.

- [ ] **Step 3: Verify import resolves**

Run: `cd packages/screen_recorder && dart pub deps | grep package_info_plus`
Expected: shows `package_info_plus`.

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder/pubspec.yaml packages/screen_recorder/pubspec.lock
git commit -m "build(settings): add package_info_plus for the About section (#2)"
```

---

### Task 7: Rewrite `SettingsScreen` as global preferences

**Files:**
- Modify (full rewrite): `packages/screen_recorder/lib/ui/screens/settings_screen.dart`
- Test: `packages/screen_recorder/test/ui/screens/settings_screen_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/screens/settings_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/global_preferences_controller.dart';
import 'package:screen_recorder/state/global_preferences_store.dart';
import 'package:screen_recorder/state/permissions_controller.dart';
import 'package:screen_recorder/state/recording_settings_controller.dart';
import 'package:screen_recorder/state/recording_settings_store.dart';
import 'package:screen_recorder/ui/screens/settings_screen.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Minimal platform stub — same pattern as test/state/sleep_observer_test.dart.
/// ScreenRecorderPlatform's methods have default bodies, so an empty subclass
/// compiles; PermissionsController only touches it on refreshAll()/request(),
/// both of which the screen guards or doesn't invoke in this test.
class _FakePlatform extends ScreenRecorderPlatform {}

Widget _app(Widget child, List<Override> overrides) => ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: ThemeData.dark().copyWith(
          // Use the real default palette constant exported by app_palette.dart.
          // If the name differs, read that file and substitute it here.
          extensions: [AppPalette.midnight],
        ),
        home: child,
      ),
    );

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    ScreenRecorderPlatform.instance = _FakePlatform();
  });

  final overrides = <Override>[
    recordingSettingsControllerProvider.overrideWith((ref) =>
        RecordingSettingsController(
            store: RecordingSettingsStore(path: '/tmp/x_rec.json'),
            initial: RecordingSettings.defaults)),
    globalPreferencesControllerProvider.overrideWith((ref) =>
        GlobalPreferencesController(
            store: GlobalPreferencesStore(path: '/tmp/x_glob.json'),
            initial: GlobalPreferences.defaults)),
    permissionsControllerProvider.overrideWith(
        (ref) => PermissionsController(ScreenRecorderPlatform.instance)),
  ];

  testWidgets('shows global sections, not frame styling or alert demo',
      (tester) async {
    await tester.pumpWidget(_app(const SettingsScreen(), overrides));
    await tester.pump();

    expect(find.text('Recording'), findsOneWidget);
    expect(find.text('Permissions'), findsOneWidget);
    expect(find.text('Default save location'), findsOneWidget);
    expect(find.text('About'), findsOneWidget);

    // Removed concerns must be gone.
    expect(find.text('Alert demo'), findsNothing);
    expect(find.text('Padding'), findsNothing);
    expect(find.text('Corner Radius'), findsNothing);
    expect(find.text('Background Color'), findsNothing);
  });

  testWidgets('save location shows the Ask-each-time default when unset',
      (tester) async {
    await tester.pumpWidget(_app(const SettingsScreen(), overrides));
    await tester.pump();
    expect(find.textContaining('Ask each time'), findsOneWidget);
  });
}
```

> Note on `AppPalette.midnight`: use whatever the concrete palette constant is exported by `ui/theme/app_palette.dart`. If the named constants differ, the implementer should read that file and use the real default palette instance in the test `extensions:` list. The production app always supplies an `AppPalette` extension, so `context.palette` is safe at runtime.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/screens/settings_screen_test.dart`
Expected: FAIL — current `SettingsScreen` requires `frame`/`onChanged` and shows frame controls.

- [ ] **Step 3: Replace the whole file**

Replace `packages/screen_recorder/lib/ui/screens/settings_screen.dart` with:

```dart
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../state/global_preferences_controller.dart';
import '../../state/permissions_controller.dart';
import '../../state/recording_settings_controller.dart';
import '../theme/app_palette_context.dart';
import '../widgets/permission_denied_sheet.dart';
import '../widgets/permission_status_row.dart';
import 'theme_playground_screen.dart';

/// Global app preferences: recording defaults, appearance, permissions,
/// default save location, a read-only shortcut reference, and About.
/// Per-clip frame styling lives in the editor inspector's Background tab.
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  static const _permissionKinds = [
    PermissionKind.screenRecording,
    PermissionKind.microphone,
    PermissionKind.camera,
    PermissionKind.accessibility,
  ];
  static const _permLabels = {
    PermissionKind.screenRecording: 'Screen Recording',
    PermissionKind.microphone: 'Microphone',
    PermissionKind.camera: 'Camera',
    PermissionKind.accessibility: 'Accessibility',
  };
  static const _permSubtitles = {
    PermissionKind.screenRecording: 'Required to capture your screen.',
    PermissionKind.microphone: 'Optional — for voice narration.',
    PermissionKind.camera: 'Optional — for webcam / facecam.',
    PermissionKind.accessibility: 'Optional — for richer click tracking.',
  };

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        ref.read(permissionsControllerProvider.notifier).refreshAll();
      } catch (_) {/* provider not overridden in some hosts */}
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.palette.appBackground,
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: context.palette.surfaceElevated,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: context.palette.dividerSubtle),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _title('Recording'),
            const SizedBox(height: 12),
            _countdownPicker(),
            const SizedBox(height: 32),

            _title('Appearance'),
            const SizedBox(height: 12),
            _appearanceCard(),
            const SizedBox(height: 32),

            _title('Permissions'),
            const SizedBox(height: 12),
            _permissionsCard(),
            const SizedBox(height: 32),

            _title('Default save location'),
            const SizedBox(height: 12),
            _saveLocationCard(),
            const SizedBox(height: 32),

            _title('Keyboard shortcuts'),
            const SizedBox(height: 12),
            _shortcutsCard(),
            const SizedBox(height: 32),

            _title('About'),
            const SizedBox(height: 12),
            _aboutCard(),
          ],
        ),
      ),
    );
  }

  Widget _title(String t) => Text(
        t,
        style: TextStyle(
          color: context.palette.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      );

  Widget _card({required Widget child, EdgeInsets? padding}) => Container(
        width: double.infinity,
        padding: padding ?? const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: context.palette.surfaceCard,
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      );

  Widget _countdownPicker() {
    final value = ref.watch(recordingSettingsControllerProvider).countdownSeconds;
    return _card(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text('Countdown before recording',
              style: TextStyle(color: context.palette.textPrimary)),
          ToggleButtons(
            isSelected: [value == 0, value == 3, value == 5],
            onPressed: (i) => ref
                .read(recordingSettingsControllerProvider.notifier)
                .setCountdownSeconds([0, 3, 5][i]),
            borderRadius: BorderRadius.circular(8),
            children: const [Text(' Off '), Text(' 3 s '), Text(' 5 s ')],
          ),
        ],
      ),
    );
  }

  Widget _appearanceCard() => _card(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: ListTile(
          leading:
              Icon(Icons.palette_outlined, color: context.palette.textPrimary),
          title: Text('Theme playground',
              style: TextStyle(color: context.palette.textPrimary)),
          subtitle: Text('Preview and pick the app theme',
              style: TextStyle(color: context.palette.textSecondary)),
          trailing:
              Icon(Icons.chevron_right, color: context.palette.textSecondary),
          contentPadding: EdgeInsets.zero,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ThemePlaygroundScreen()),
          ),
        ),
      );

  Widget _permissionsCard() {
    final snap = ref.watch(permissionsControllerProvider);
    return _card(
      child: Column(
        children: [
          for (final kind in _permissionKinds)
            PermissionStatusRow(
              kind: kind,
              label: _permLabels[kind]!,
              subtitle: _permSubtitles[kind]!,
              status: snap.byKind[kind] ?? PermissionStatus.unsupported,
              onGrant: () =>
                  ref.read(permissionsControllerProvider.notifier).request(kind),
              onOpenSettings: () => PermissionDeniedSheet.show(context, kind),
            ),
        ],
      ),
    );
  }

  Widget _saveLocationCard() {
    final path = ref.watch(globalPreferencesControllerProvider).defaultSaveLocation;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            path ?? 'Ask each time · saved to Documents',
            style: TextStyle(
              color:
                  path == null ? context.palette.textSecondary : context.palette.textPrimary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.tonal(
                onPressed: _chooseFolder,
                child: const Text('Choose…'),
              ),
              const SizedBox(width: 8),
              if (path != null)
                TextButton(
                  onPressed: () => ref
                      .read(globalPreferencesControllerProvider.notifier)
                      .setDefaultSaveLocation(null),
                  child: const Text('Reset'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _chooseFolder() async {
    final dir = await getDirectoryPath();
    if (dir == null) return;
    await ref
        .read(globalPreferencesControllerProvider.notifier)
        .setDefaultSaveLocation(dir);
  }

  Widget _shortcutsCard() {
    const rows = [
      ('⌘⇧1', 'Start recording'),
      ('⌘⇧2', 'Stop recording'),
      ('⌘⇧P', 'Pause / Resume'),
    ];
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final r in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                SizedBox(
                  width: 56,
                  child: Text(r.$1,
                      style: TextStyle(
                          color: context.palette.textPrimary,
                          fontFamily: 'Menlo')),
                ),
                Text(r.$2,
                    style: TextStyle(color: context.palette.textSecondary)),
              ]),
            ),
        ],
      ),
    );
  }

  Widget _aboutCard() => _card(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FutureBuilder<PackageInfo>(
              future: _packageInfo(),
              builder: (context, snap) {
                final info = snap.data;
                final version = info == null
                    ? '…'
                    : '${info.version} (${info.buildNumber})';
                return Text(
                  'Slipreel · v$version',
                  style: TextStyle(
                      color: context.palette.textPrimary,
                      fontWeight: FontWeight.w500),
                );
              },
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.system_update_alt,
                  color: context.palette.textSecondary),
              title: Text('Check for updates',
                  style: TextStyle(color: context.palette.textSecondary)),
              subtitle: Text('Coming soon',
                  style: TextStyle(color: context.palette.textSecondary)),
              enabled: false,
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading:
                  Icon(Icons.public, color: context.palette.textPrimary),
              title: Text('Website',
                  style: TextStyle(color: context.palette.textPrimary)),
              trailing: Icon(Icons.open_in_new,
                  size: 16, color: context.palette.textSecondary),
              onTap: () => launchUrl(Uri.parse('https://slipreel.app')),
            ),
          ],
        ),
      );

  Future<PackageInfo> _packageInfo() async {
    try {
      return await PackageInfo.fromPlatform();
    } catch (_) {
      // No platform channel (e.g. widget tests). Show a placeholder.
      return PackageInfo(
        appName: 'Slipreel',
        packageName: 'com.slipreel.app',
        version: '0.0.0',
        buildNumber: '0',
      );
    }
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/screens/settings_screen_test.dart`
Expected: PASS (2 tests). If `AppPalette.midnight` is the wrong constant name, read `lib/ui/theme/app_palette.dart` and use the real default palette in the test harness.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/settings_screen.dart \
        packages/screen_recorder/test/ui/screens/settings_screen_test.dart
git commit -m "feat(settings): rewrite Settings as global app preferences (#2)"
```

---

### Task 8: Wire entry points; remove the editor frame-settings button

**Files:**
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart` (`:40` field, `:267-271` gear case)
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (`_openFrameSettings` ~`:1670-1689`, toolbar button ~`:2885-2893`)

- [ ] **Step 1: Update the bar gear menu**

In `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart`, replace the `'settings'` case (`:267-271`):

```dart
      case 'settings':
        await _openPanel(SettingsScreen(
          frame: _barFrame,
          onChanged: (next) => setState(() => _barFrame = next),
        ));
```

with:

```dart
      case 'settings':
        await _openPanel(const SettingsScreen());
```

Then delete the now-unused `_barFrame` field (`:40`, `late WindowFrame _barFrame = WindowFrame.rounded();` or similar — remove the whole declaration). If `WindowFrame` is now an unused import in this file, remove that import too.

- [ ] **Step 2: Remove the editor frame-settings button**

In `packages/screen_recorder/lib/ui/screens/playback_screen.dart`, delete the `IconButton` that calls `_openFrameSettings` (~`:2885-2893`, the block with `onPressed: _openFrameSettings`, `tooltip: 'Frame Settings'`). Then delete the `_openFrameSettings` method (~`:1670-1689`). If this removes the only use of the `SettingsScreen` import in `playback_screen.dart`, remove that import; keep all other imports.

- [ ] **Step 3: Verify it compiles**

Run: `cd packages/screen_recorder && flutter analyze lib/ui/bar/recording_bar_screen.dart lib/ui/screens/playback_screen.dart`
Expected: `No issues found!` (no unused-import / undefined-name warnings).

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart \
        packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat(settings): bar gear is the single Settings entry; drop editor frame-settings button (#2)"
```

---

### Task 9: Full-suite analyze + test sweep

**Files:** none (verification)

- [ ] **Step 1: Analyze the package**

Run: `cd packages/screen_recorder && flutter analyze lib`
Expected: `No issues found!`

- [ ] **Step 2: Run the affected test areas**

Run: `cd packages/screen_recorder && flutter test test/state/ test/services/ test/ui/widgets/permission_status_row_test.dart test/ui/screens/settings_screen_test.dart`
Expected: all pass.

- [ ] **Step 3: Commit (only if any fix was needed)**

```bash
git add -A && git commit -m "test(settings): green sweep for global-prefs rework (#2)"
```

---

## Notes for the implementer

- The recording-bar window (`RecordingBar`) is custom-chrome and intentionally NOT migrated to `AppPalette` (per project convention). The `SettingsScreen` itself DOES use `context.palette`; it's pushed inside `_openPanel`, which provides a normal Material context, so `context.palette` resolves there.
- Don't touch the inspector Background tab or the `WindowFrame` model — per-clip frame styling stays exactly as-is.
- `getSaveLocation` and `getDirectoryPath` both come from `file_selector` (already a dependency). `getSaveLocation` accepts `initialDirectory` in the version used here (the existing call already uses the `suggestedName` + `acceptedTypeGroups` named-parameter form).
