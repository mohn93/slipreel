import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:screen_recorder/licensing/build_release_date.g.dart';
import 'package:screen_recorder/licensing/entitlement.dart';
import 'package:screen_recorder/licensing/export_gate.dart';
import 'package:screen_recorder/licensing/licensing_controller.dart';
import 'package:screen_recorder/ui/app_alerts/app_alerts.dart';
import 'package:screen_recorder/ui/theme/app_palette_context.dart';

/// The export paywall. Blocks export for unentitled users and starts the
/// browser purchase/sign-in flow. Watches [entitlementProvider]; when export
/// becomes allowed (the Phase 5b deep link lands) it auto-dismisses with true
/// so the caller proceeds straight into export.
class PaywallSheet {
  const PaywallSheet._();

  /// Returns true if the user became entitled while the sheet was open.
  static Future<bool> show(
    BuildContext context, {
    required PaywallReason reason,
  }) async {
    final result = await showModalBottomSheet<bool>(
      context: context,
      isDismissible: true,
      showDragHandle: true,
      backgroundColor: context.palette.surfaceElevated,
      builder: (_) => _PaywallBody(reason: reason),
    );
    return result ?? false;
  }
}

class _PaywallBody extends ConsumerStatefulWidget {
  const _PaywallBody({required this.reason});
  final PaywallReason reason;

  @override
  ConsumerState<_PaywallBody> createState() => _PaywallBodyState();
}

class _PaywallBodyState extends ConsumerState<_PaywallBody> {
  bool _busy = false;

  ({String title, String body}) _copy(PaywallReason reason) {
    switch (reason) {
      case PaywallReason.needsPurchase:
        return (
          title: 'Exporting is a paid feature',
          body: 'Recording and editing are free. Choose a subscription or a '
              'one-time purchase (perpetual export plus one year of updates) '
              'on the next screen.',
        );
      case PaywallReason.subscriptionLapsed:
        return (
          title: 'Your subscription has lapsed',
          body: 'Export is locked until your subscription is active again. '
              'Manage or renew it on the next screen.',
        );
      case PaywallReason.updateCeiling:
        return (
          title: 'Renew your update year',
          body: 'Your one-time license covers versions released within your '
              'update window. This build is newer, so export is locked here. '
              'Renew another year of updates to export on the latest version '
              'your earlier build still exports as before.',
        );
    }
  }

  Future<void> _run(Future<bool> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ok = await action();
      if (!ok && mounted) {
        AppAlerts.error('Could not open the browser. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Auto-advance: the instant export becomes allowed, close with success.
    ref.listen<EntitlementState>(entitlementProvider, (_, next) {
      if (canExportNow(next, appReleaseDate: buildReleaseDate)) {
        Navigator.of(context).maybePop(true);
      }
    });

    final palette = context.palette;
    final copy = _copy(widget.reason);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(copy.title,
                style: TextStyle(
                    color: palette.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Text(copy.body,
                style: TextStyle(color: palette.textSecondary, height: 1.4)),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _busy
                  ? null
                  : () => _run(
                      ref.read(licensingControllerProvider.notifier).unlockExport),
              style: ElevatedButton.styleFrom(
                  backgroundColor: palette.accent,
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              child: Text(widget.reason == PaywallReason.needsPurchase
                  ? 'Unlock export'
                  : 'Continue'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(
                      ref.read(licensingControllerProvider.notifier).openSignIn),
              child: Text('Already purchased? Sign in',
                  style: TextStyle(color: palette.textSecondary)),
            ),
          ],
        ),
      ),
    );
  }
}
