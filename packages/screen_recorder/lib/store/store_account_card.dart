import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../licensing/build_release_date.g.dart';
import '../licensing/entitlement.dart';
import '../licensing/export_gate.dart';
import '../licensing/licensing_controller.dart';
import '../licensing/trial_exports.dart';
import '../ui/theme/app_palette_context.dart';
import '../ui/widgets/desktop_dialog.dart';
import 'native_account.dart';
import 'store_account_dialog.dart';
import 'store_paywall.dart';

/// Account status is separate from checkout: paid users never see an upsell.
class StoreAccountCard extends ConsumerStatefulWidget {
  const StoreAccountCard({super.key, required this.state});
  final EntitlementAppStore state;
  @override
  ConsumerState<StoreAccountCard> createState() => _StoreAccountCardState();
}

class _StoreAccountCardState extends ConsumerState<StoreAccountCard> {
  bool _busy = false;
  String? _notice;
  @override
  void initState() {
    super.initState();
    Future.microtask(() => _run(() => ref.read(nativeAccountProvider).load()));
  }

  Future<void> _run(Future<void> Function() action, {String? success}) async {
    if (_busy || !mounted) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      await action();
      if (mounted) setState(() => _notice = success);
    } catch (e) {
      if (mounted) {
        setState(
          () => _notice = e is AccountError
              ? e.message
              : 'Could not refresh your account. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final account = ref.watch(nativeAccountProvider);
    final state = widget.state;
    final active = canExportNow(state, appReleaseDate: buildReleaseDate);
    final apple = state.activeAt(DateTime.now());
    final reason = paywallReasonFor(state, appReleaseDate: buildReleaseDate);
    final recovery =
        reason == PaywallReason.licenseCheckRequired ||
        reason == PaywallReason.updateCeiling;
    final title = active
        ? 'Your next video. No limits.'
        : recovery
        ? 'Let’s reconnect your access.'
        : 'Make it. Share it.';
    final plan = apple
        ? (state.productId!.endsWith('.yearly')
              ? 'Pro · Yearly'
              : 'Pro · Monthly')
        : active
        ? 'Pro · Account access'
        : 'Free recording & editing';
    int? remaining;
    if (!active) {
      try {
        remaining = ref.watch(trialExportsRemainingProvider).valueOrNull;
      } catch (_) {
        /* optional in preview hosts */
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: p.accentMuted,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                Icons.motion_photos_on_rounded,
                color: p.accent,
                size: 28,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Slipreel',
                    style: TextStyle(
                      color: p.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    plan,
                    style: TextStyle(color: p.textSecondary, fontSize: 13),
                  ),
                ],
              ),
            ),
            if (active)
              Tooltip(
                message: 'Unlimited exports active',
                child: Icon(Icons.verified_rounded, color: p.accent),
              ),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          title,
          style: TextStyle(
            color: p.textPrimary,
            fontSize: 27,
            height: 1.15,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.6,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          active
              ? 'Unlimited full-quality exports are ready whenever you are.'
              : recovery
              ? 'Check your existing license before choosing another plan.'
              : 'Record and edit for free. Go Pro when you’re ready for unlimited exports.',
          style: TextStyle(color: p.textSecondary, height: 1.5),
        ),
        if (apple && state.expiresAt != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              'Current access through ${MaterialLocalizations.of(context).formatShortDate(state.expiresAt!.toLocal())}',
              style: TextStyle(color: p.textSecondary, fontSize: 12),
            ),
          ),
        if (!active && remaining != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              '$remaining of ${TrialExports.limit} free exports left',
              style: TextStyle(color: p.textSecondary, fontSize: 13),
            ),
          ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (!active)
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => showDesktopDialog<bool>(
                        context: context,
                        builder: (_) => StorePaywall(reason: reason),
                      ),
                child: Text(
                  recovery ? 'Verify access' : 'Unlock unlimited exports',
                ),
              ),
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => showDesktopDialog<bool>(
                      context: context,
                      builder: (_) => const StoreAccountDialog(),
                    ),
              child: Text(account.signedIn ? 'Manage account' : 'Sign in'),
            ),
            if (state.productId != null)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => ref
                            .read(licensingControllerProvider.notifier)
                            .appStore!
                            .manageSubscriptions(),
                      ),
                child: const Text('Manage subscription'),
              ),
          ],
        ),
        const SizedBox(height: 20),
        Divider(color: p.dividerSubtle),
        const SizedBox(height: 8),
        Text(
          account.signedIn
              ? account.email!
              : 'Already purchased? Sign in with the same Slipreel account.',
          style: TextStyle(color: p.textSecondary, fontSize: 13),
        ),
        Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(
                      () async {
                        final controller = ref.read(
                          licensingControllerProvider.notifier,
                        );
                        await controller.appStore!.restore();
                        await account.load();
                        if (account.signedIn) await account.syncPurchases();
                        await controller.refreshNow();
                        if (!canExportNow(
                          ref.read(entitlementProvider),
                          appReleaseDate: buildReleaseDate,
                        )) {
                          throw const AccountError(
                            'No active purchase found. Check your Apple Account or sign in to your existing Slipreel account.',
                          );
                        }
                      },
                      success:
                          'Purchases restored. Unlimited exports are active.',
                    ),
              child: const Text('Restore purchases'),
            ),
            if (account.signedIn || _notice != null)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        await account.load();
                        if (account.signedIn) await account.syncPurchases();
                      }, success: 'Account access refreshed.'),
                child: const Text('Refresh access'),
              ),
          ],
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_notice != null)
          Semantics(
            liveRegion: true,
            child: Text(
              _notice!,
              style: TextStyle(color: p.textSecondary, height: 1.4),
            ),
          ),
      ],
    );
  }
}
