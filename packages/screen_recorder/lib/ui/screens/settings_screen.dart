import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart'
    hide RecordingSettings;
import 'package:url_launcher/url_launcher.dart';

import '../../analytics/analytics_events.dart';
import '../../analytics/analytics_service.dart';
import '../../licensing/build_release_date.g.dart';
import '../../licensing/entitlement.dart';
import '../../licensing/entitlement_claims.dart';
import '../../licensing/export_gate.dart';
import '../../licensing/licensing_controller.dart';
import '../../licensing/trial_exports.dart';
import '../../state/global_preferences_controller.dart';
import '../../state/permissions_controller.dart';
import '../../state/recording_settings_controller.dart';
import '../../update/updater_service.dart';
import '../feedback/feedback_sheet.dart';
import '../theme/app_palette_context.dart';
import '../widgets/permission_denied_sheet.dart';
import '../widgets/permission_status_row.dart';
import '../widgets/request_permission.dart';
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
    ref.captureAnalytics(AnalyticsEvents.screenViewed,
        properties: {'screen': 'settings'});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        ref.read(permissionsControllerProvider.notifier).refreshAll();
      } catch (_) {/* provider not overridden in some hosts */}
    });
  }

  // Licensing is not wired in every host (e.g. widget tests that don't
  // override licensingControllerProvider); hide the Account section there
  // instead of letting the unimplemented provider throw during build.
  EntitlementState? _watchEntitlement() {
    try {
      return ref.watch(entitlementProvider);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final entitlement = _watchEntitlement();
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
            if (entitlement != null) ...[
              _title('Account'),
              const SizedBox(height: 12),
              _accountCard(entitlement),
              const SizedBox(height: 32),
            ],

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

            _title('Privacy'),
            const SizedBox(height: 12),
            _privacyCard(),
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

  // ---- Account -------------------------------------------------------------

  Widget _accountCard(EntitlementState state) => _card(
        child: switch (state) {
          EntitlementLoading() => Row(
              children: [
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                Text('Checking your license…',
                    style: TextStyle(color: context.palette.textSecondary)),
              ],
            ),
          EntitlementSignedOut() => _accountSignedOut(),
          EntitlementLoaded(:final claims) => _accountLoaded(state, claims),
        },
      );

  Widget _accountSignedOut() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Not signed in',
              style: TextStyle(
                  color: context.palette.textPrimary,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('Sign in to activate this Mac and manage your plan.',
              style: TextStyle(color: context.palette.textSecondary)),
          _trialLine(),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _openSignIn,
            child: const Text('Sign in'),
          ),
        ],
      );

  // The device-local free-export allowance (mirrors the editor's export
  // button). Shown only when the user is not entitled; hidden when the trial
  // provider isn't wired (e.g. widget tests that don't override it).
  Widget _trialLine() {
    int? remaining;
    try {
      remaining = ref.watch(trialExportsRemainingProvider).valueOrNull;
    } catch (_) {
      remaining = null;
    }
    if (remaining == null) return const SizedBox.shrink();
    final text = remaining > 0
        ? '$remaining of ${TrialExports.limit} free exports left'
        : 'No free exports left';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(text,
          style: TextStyle(color: context.palette.textSecondary, fontSize: 13)),
    );
  }

  Widget _accountLoaded(EntitlementState state, EntitlementClaims claims) {
    final (name, detail, dot) = _accountDisplay(claims);
    final entitled = canExportNow(state, appReleaseDate: buildReleaseDate);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 10,
              height: 10,
              margin: const EdgeInsets.only(top: 5),
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(name,
                      style: TextStyle(
                          color: context.palette.textPrimary,
                          fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(detail,
                      style: TextStyle(
                          color: context.palette.textSecondary, fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
        if (!entitled) _trialLine(),
        const SizedBox(height: 16),
        if (entitled)
          FilledButton.tonal(
            onPressed: _manageAccount,
            child: const Text('Manage account'),
          )
        else
          Row(
            children: [
              FilledButton(
                onPressed: _upgrade,
                child: const Text('Upgrade'),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: _manageAccount,
                child: const Text('Manage account'),
              ),
            ],
          ),
      ],
    );
  }

  /// (headline, detail, status-dot colour) for the current claims — mirrors the
  /// web account page's states.
  (String, String, Color) _accountDisplay(EntitlementClaims c) {
    const green = Color(0xFF4ADE80);
    const amber = Color(0xFFFBBF24);
    final grey = context.palette.textSecondary;
    switch (c.plan) {
      case 'subscription':
        if (c.status == 'grace') {
          return (
            'Pro — Monthly',
            'Payment issue — update your card to keep exporting.',
            amber
          );
        }
        if (c.status == 'active') {
          return ('Pro — Monthly', 'Active · unlimited exports.', green);
        }
        return (
          'Pro — Monthly',
          'Inactive — resubscribe to unlock exports.',
          grey
        );
      case 'onetime':
        final until = c.updatesUntil;
        if (until != null && buildReleaseDate.isAfter(until)) {
          return (
            'Lifetime license',
            'Updates ended ${_date(until)} — renew to update.',
            amber
          );
        }
        return (
          'Lifetime license',
          until != null
              ? 'Active · free updates through ${_date(until)}.'
              : 'Active · unlimited exports.',
          green
        );
      default:
        return (
          'No active license',
          'Records and edits are free. Unlock unlimited exports.',
          grey
        );
    }
  }

  String _date(DateTime dt) =>
      MaterialLocalizations.of(context).formatShortDate(dt.toLocal());

  Future<void> _manageAccount() async {
    try {
      await ref.read(licensingControllerProvider.notifier).openAccount();
    } catch (_) {/* browser unavailable — nothing to do */}
  }

  Future<void> _openSignIn() async {
    try {
      await ref.read(licensingControllerProvider.notifier).openSignIn();
    } catch (_) {/* browser unavailable — nothing to do */}
  }

  Future<void> _upgrade() async {
    try {
      await ref.read(licensingControllerProvider.notifier).unlockExport();
    } catch (_) {/* browser unavailable — nothing to do */}
  }

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

  Widget _privacyCard() {
    final shareAnalytics = ref.watch(
        globalPreferencesControllerProvider.select((p) => p.shareAnalytics));
    final shareDiagnostics = ref.watch(
        globalPreferencesControllerProvider.select((p) => p.shareDiagnostics));
    return _card(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Column(
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Share usage data',
                style: TextStyle(color: context.palette.textPrimary)),
            subtitle: Text(
              'Feature usage is associated with your account while signed in. '
              'Never includes recordings, file names, or screen contents.',
              style: TextStyle(color: context.palette.textSecondary),
            ),
            value: shareAnalytics,
            onChanged: (v) => ref
                .read(globalPreferencesControllerProvider.notifier)
                .setShareAnalytics(v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Send crash & error reports',
                style: TextStyle(color: context.palette.textPrimary)),
            subtitle: Text(
              'Sends technical reports, associated with your account while signed in. '
              'File paths are stripped; recordings are never included.',
              style: TextStyle(color: context.palette.textSecondary),
            ),
            value: shareDiagnostics,
            onChanged: (v) => ref
                .read(globalPreferencesControllerProvider.notifier)
                .setShareDiagnostics(v),
          ),
          ListTile(
            leading: Icon(Icons.feedback_outlined,
                color: context.palette.textPrimary),
            title: Text('Send feedback',
                style: TextStyle(color: context.palette.textPrimary)),
            subtitle: Text('Share an idea or report a problem',
                style: TextStyle(color: context.palette.textSecondary)),
            trailing: Icon(Icons.chevron_right,
                color: context.palette.textSecondary),
            contentPadding: EdgeInsets.zero,
            onTap: () => FeedbackSheet.show(context),
          ),
        ],
      ),
    );
  }

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
              // Screen Recording falls back to the deny sheet (Open System
              // Settings + drag-to-add guide) when Enable can't grant it.
              onGrant: () => requestPermissionWithGuide(context, ref, kind),
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
                  final entitlement = ref.read(entitlementProvider);
                  final claims = entitlement is EntitlementLoaded
                      ? entitlement.claims
                      : null;
                  if (claims?.plan != 'subscription' ||
                      !canExport(claims, appReleaseDate: buildReleaseDate)) {
                    final until = claims?.updatesUntil?.toUtc();
                    final ceiling = until == null
                        ? 'your included update period'
                        : '${until.year}-${until.month.toString().padLeft(2, '0')}-${until.day.toString().padLeft(2, '0')}';
                    final proceed = await showDialog<bool>(
                      context: context,
                      builder: (ctx) => AlertDialog(
                        title: const Text('Check license compatibility'),
                        content: Text(
                          'A one-time license covers releases through $ceiling (UTC). '
                          'Installing a newer release may require renewing updates to export. '
                          'Compare the release date before installing, or download an earlier version.',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () {
                              launchUrl(
                                Uri.parse('https://slipreel.app/downloads'),
                              );
                              Navigator.pop(ctx, false);
                            },
                            child: const Text('Earlier versions'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(ctx, false),
                            child: const Text('Cancel'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(ctx, true),
                            child: const Text('Check for updates'),
                          ),
                        ],
                      ),
                    );
                    if (proceed != true) return;
                  }
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
