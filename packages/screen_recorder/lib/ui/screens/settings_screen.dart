import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart'
    hide RecordingSettings;
import 'package:url_launcher/url_launcher.dart';

import '../../state/global_preferences_controller.dart';
import '../../state/permissions_controller.dart';
import '../../state/recording_settings_controller.dart';
import '../../update/updater_service.dart';
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
    PermissionKind.camera,
    PermissionKind.microphone,
    PermissionKind.accessibility,
  ];
  static const _permLabels = {
    PermissionKind.screenRecording: 'Screen Recording',
    PermissionKind.camera: 'Camera',
    PermissionKind.microphone: 'Microphone',
    PermissionKind.accessibility: 'Accessibility',
  };
  static const _permSubtitles = {
    PermissionKind.screenRecording: 'Required to capture your screen.',
    PermissionKind.camera: 'Optional — for webcam / facecam.',
    PermissionKind.microphone: 'Optional — for voice narration.',
    PermissionKind.accessibility: 'Optional — for richer click tracking.',
  };
  static const _permIcons = {
    PermissionKind.screenRecording: Icons.desktop_windows_outlined,
    PermissionKind.camera: Icons.videocam_outlined,
    PermissionKind.microphone: Icons.mic_none_outlined,
    PermissionKind.accessibility: Icons.keyboard_outlined,
  };

  // Resolved once — a fresh Future each build would make FutureBuilder
  // re-fire the platform call and flicker back to the placeholder on every
  // provider-driven rebuild.
  late final Future<PackageInfo> _packageInfoFuture = _packageInfo();

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

  // Use a Material (not a DecoratedBox/Container-with-color) as the card
  // surface: cards host onTap ListTiles, and Flutter 3.44+ asserts when a
  // ListTile's nearest Material ancestor is hidden behind an intermediate
  // colored DecoratedBox (ink splashes / bg become invisible). The Material
  // is the colored surface; the inner Container only sizes + pads.
  Widget _card({required Widget child, EdgeInsets? padding}) => Material(
        color: context.palette.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          padding: padding ?? const EdgeInsets.all(16),
          child: child,
        ),
      );

  Widget _countdownPicker() {
    final value =
        ref.watch(recordingSettingsControllerProvider).countdownSeconds;
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
              icon: _permIcons[kind]!,
              label: _permLabels[kind]!,
              subtitle: _permSubtitles[kind]!,
              status: snap.byKind[kind] ?? PermissionStatus.unsupported,
              // See PermissionsPage: Screen Recording must fire the request
              // even from a `denied` state so macOS registers the app.
              canRequestWhenDenied: kind == PermissionKind.screenRecording,
              onGrant: () =>
                  ref.read(permissionsControllerProvider.notifier).request(kind),
              onOpenSettings: () => PermissionDeniedSheet.show(context, kind),
            ),
        ],
      ),
    );
  }

  Widget _saveLocationCard() {
    final path =
        ref.watch(globalPreferencesControllerProvider).defaultSaveLocation;
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            path ?? 'Ask each time · saved to Documents',
            style: TextStyle(
              color: path == null
                  ? context.palette.textSecondary
                  : context.palette.textPrimary,
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
    if (dir == null || !mounted) return;
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
              future: _packageInfoFuture,
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
                  color: context.palette.textPrimary),
              title: Text('Check for updates',
                  style: TextStyle(color: context.palette.textPrimary)),
              trailing: Icon(Icons.chevron_right,
                  size: 16, color: context.palette.textSecondary),
              onTap: () async {
                try {
                  await ref.read(updaterServiceProvider).checkForUpdates();
                } catch (_) {
                  // Sparkle unavailable (non-macOS / test host) — nothing to do.
                }
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.public, color: context.palette.textPrimary),
              title: Text('Website',
                  style: TextStyle(color: context.palette.textPrimary)),
              trailing: Icon(Icons.open_in_new,
                  size: 16, color: context.palette.textSecondary),
              onTap: () async {
                try {
                  await launchUrl(Uri.parse('https://slipreel.app'));
                } catch (_) {/* browser unavailable — nothing to do */}
              },
            ),
          ],
        ),
      );

  Future<PackageInfo> _packageInfo() async {
    try {
      return await PackageInfo.fromPlatform();
    } catch (_) {
      return PackageInfo(
        appName: 'Slipreel',
        packageName: 'com.slipreel.app',
        version: '0.0.0',
        buildNumber: '0',
      );
    }
  }
}
