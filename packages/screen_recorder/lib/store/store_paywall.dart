import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../licensing/licensing_controller.dart';
import '../licensing/entitlement.dart';
import '../licensing/export_gate.dart';
import '../licensing/build_release_date.g.dart';
import '../ui/theme/app_palette_context.dart';
import '../ui/widgets/desktop_dialog.dart';
import 'app_store_client.dart';
import 'native_account.dart';
import 'store_account_dialog.dart';

class StorePaywall extends ConsumerStatefulWidget {
  const StorePaywall({super.key, this.reason});
  final PaywallReason? reason;
  @override
  ConsumerState<StorePaywall> createState() => _StorePaywallState();
}

class _StorePaywallState extends ConsumerState<StorePaywall> {
  List<StoreProduct>? _products;
  String? _selectedId;
  bool _busy = false;
  bool _pending = false;
  String? _message;
  AppStoreClient get store =>
      ref.read(licensingControllerProvider.notifier).appStore!;
  bool get _entitled => canExportNow(
    ref.read(entitlementProvider),
    appReleaseDate: buildReleaseDate,
  );
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _message = null;
      _products = null;
    });
    try {
      final products = (await store.products()).toList();
      products.sort(
        (a, b) => (a.isYearly ? 1 : 0).compareTo(b.isYearly ? 1 : 0),
      );
      if (!mounted) return;
      setState(() {
        _products = products;
        _selectedId = products.any((p) => p.id == _selectedId)
            ? _selectedId
            : products.firstOrNull?.id;
        if (products.isEmpty) {
          _message =
              'Plans are unavailable right now. Your project is safe. Try again in a moment.';
        }
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _products = [];
          _message =
              'Plans could not load. Check your connection and try again.';
        });
      }
    }
  }

  Future<void> _perform(Future<String?> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final message = await action();
      await ref.read(licensingControllerProvider.notifier).refreshNow();
      if (!mounted) return;
      if (_entitled && message == null) {
        Navigator.pop(context, true);
      } else {
        setState(() => _message = message);
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = e is AccountError
              ? e.message
              : 'This request could not finish. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _signIn() async {
    final account = ref.read(nativeAccountProvider);
    await account.load();
    if (!mounted) return false;
    if (!account.signedIn) {
      await showDesktopDialog<bool>(
        context: context,
        builder: (_) => const StoreAccountDialog(),
      );
    }
    if (account.signedIn) await account.activate();
    return account.signedIn;
  }

  Future<String?> _purchase(StoreProduct product) async {
    if (!await _signIn()) {
      return 'Sign in when you’re ready to link your subscription.';
    }
    // Recheck after account activation, immediately before checkout, so an
    // existing website subscription never leads to a second purchase.
    await ref.read(licensingControllerProvider.notifier).refreshNow();
    if (_entitled) return null;
    final result = await store.purchase(
      product.id,
      ref.read(nativeAccountProvider).appAccountToken!,
    );
    if (result == 'purchased') {
      try {
        await ref.read(nativeAccountProvider).syncPurchases();
      } catch (_) {
        return 'Purchase complete. Access on this Mac is ready; account sync needs a retry in Settings.';
      }
      return null;
    }
    if (result == 'pending') {
      _pending = true;
      return 'Waiting for purchase approval. You can keep editing; access updates when Apple approves it.';
    }
    if (result == 'cancelled') {
      return 'Purchase cancelled. You can keep editing and return whenever you’re ready.';
    }
    return 'The purchase did not finish. Please try again or restore an existing purchase.';
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(entitlementProvider);
    final entitled = canExportNow(state, appReleaseDate: buildReleaseDate);
    final reason =
        widget.reason ??
        paywallReasonFor(state, appReleaseDate: buildReleaseDate);
    final verify = reason == PaywallReason.licenseCheckRequired;
    final ceiling = reason == PaywallReason.updateCeiling;
    final recovery = verify || ceiling;
    final lapsed = reason == PaywallReason.subscriptionLapsed;
    // Pending approval resumes export only when this route is current. Never
    // pop an account dialog that is sitting above the paywall.
    ref.listen<EntitlementState>(entitlementProvider, (_, next) {
      if (!_busy &&
          widget.reason != null &&
          ModalRoute.of(context)?.isCurrent == true &&
          canExportNow(next, appReleaseDate: buildReleaseDate)) {
        Navigator.of(context).pop(true);
      }
    });
    final p = context.palette;
    final selected = _products?.where((x) => x.id == _selectedId).firstOrNull;
    final title = entitled
        ? 'You’re ready to export.'
        : verify
        ? 'Let’s reconnect your access.'
        : ceiling
        ? 'This version needs newer access.'
        : lapsed
        ? 'Get back to unlimited exports.'
        : 'Ready for unlimited exports?';
    final detail = entitled
        ? 'Slipreel Pro is active. Your next video is ready to leave the editor.'
        : verify
        ? 'Your existing license needs an online check. You don’t need to buy again.'
        : ceiling
        ? 'Your one-time license covers earlier releases. Sign in to check your license and covered versions.'
        : 'From quick walkthroughs to your next big launch. Export as many finished videos as you need.';
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.motion_photos_on_rounded, color: p.accent, size: 26),
              const SizedBox(width: 8),
              Text(
                'Slipreel Pro',
                style: TextStyle(
                  color: p.textPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              const CloseButton(),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: TextStyle(
              color: p.textPrimary,
              fontSize: 30,
              height: 1.12,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.8,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            detail,
            style: TextStyle(color: p.textSecondary, height: 1.5, fontSize: 14),
          ),
          const SizedBox(height: 22),
          if (!recovery) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: p.surfaceCard,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    entitled
                        ? Icons.check_circle_outline_rounded
                        : Icons.movie_creation_outlined,
                    color: p.accent,
                    size: 30,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Unlimited full-quality exports',
                          style: TextStyle(
                            color: p.textPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'MP4 & GIF • Your edits, ready to share',
                          style: TextStyle(
                            color: p.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],
          if (!entitled && !recovery) ...[
            if (_products == null)
              const Padding(
                padding: EdgeInsets.all(20),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (_products?.isNotEmpty == true)
              LayoutBuilder(
                builder: (context, constraints) {
                  final cards = [
                    for (final product in _products!) _plan(product),
                  ];
                  return constraints.maxWidth < 360
                      ? Column(
                          children: [
                            for (final card in cards)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: card,
                              ),
                          ],
                        )
                      : Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (var i = 0; i < cards.length; i++) ...[
                              if (i > 0) const SizedBox(width: 12),
                              Expanded(child: cards[i]),
                            ],
                          ],
                        );
                },
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy || _pending || selected == null
                  ? null
                  : () => _perform(() => _purchase(selected)),
              style: FilledButton.styleFrom(
                backgroundColor: p.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 17),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(
                _pending
                    ? 'Waiting for approval'
                    : _busy
                    ? 'One moment…'
                    : 'Unlock unlimited exports',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (selected != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  selected.billingLabel,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.textSecondary, fontSize: 12),
                ),
              ),
          ],
          if (entitled)
            FilledButton(
              onPressed: _busy ? null : () => Navigator.pop(context, true),
              child: const Text('Continue to export'),
            ),
          if (recovery && !entitled)
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _perform(() async {
                      if (ceiling) await _signIn();
                      await ref
                          .read(licensingControllerProvider.notifier)
                          .refreshNow();
                      return _entitled
                          ? null
                          : verify
                          ? 'Access could not be verified. Check your connection or sign in again.'
                          : 'This release is still outside your license’s update window. Your covered versions remain available from your Slipreel account.';
                    }),
              child: Text(
                verify ? 'Verify existing access' : 'Check my account',
              ),
            ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: LinearProgressIndicator(),
            ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _message!,
                  style: TextStyle(color: p.textPrimary, height: 1.45),
                ),
              ),
            ),
          if (_products?.isEmpty == true && !entitled && !recovery)
            TextButton(
              onPressed: _busy ? null : _load,
              child: const Text('Retry loading plans'),
            ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            children: [
              if (!entitled)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _perform(() async {
                          if (!await _signIn()) return null;
                          return _entitled
                              ? null
                              : 'You’re signed in. No active access was found for this Slipreel account.';
                        }),
                  child: const Text('Already purchased? Sign in'),
                ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _perform(() async {
                        await store.restore();
                        final account = ref.read(nativeAccountProvider);
                        await account.load();
                        if (account.signedIn) await account.syncPurchases();
                        await ref
                            .read(licensingControllerProvider.notifier)
                            .refreshNow();
                        return _entitled
                            ? null
                            : 'No active subscription was found for this Apple Account.';
                      }),
                child: const Text('Restore purchases'),
              ),
              if (lapsed)
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _perform(() async {
                          await store.manageSubscriptions();
                          return null;
                        }),
                  child: const Text('Manage subscription'),
                ),
            ],
          ),
          if (!entitled && !recovery)
            Text(
              'Charged to your Apple Account. Auto-renews unless cancelled at least 24 hours before the period ends. Manage or cancel in Apple Account settings. Recording and editing stay free.',
              style: TextStyle(
                color: p.textSecondary,
                fontSize: 11,
                height: 1.5,
              ),
              textAlign: TextAlign.center,
            ),
          Wrap(
            alignment: WrapAlignment.center,
            children: [
              TextButton(
                onPressed: () =>
                    launchUrl(Uri.parse('https://slipreel.app/privacy')),
                child: const Text('Privacy'),
              ),
              TextButton(
                onPressed: () => launchUrl(
                  Uri.parse(
                    'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/',
                  ),
                ),
                child: const Text('Terms'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _plan(StoreProduct product) {
    final p = context.palette;
    final selected = product.id == _selectedId;
    final monthly = _products?.where((p) => !p.isYearly).firstOrNull;
    final savings = monthly == null
        ? null
        : product.savingsComparedWith(monthly);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? p.accentMuted : p.surfaceCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? p.accent : p.dividerStrong,
            width: selected ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _busy ? null : () => setState(() => _selectedId = product.id),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        product.isYearly ? 'Yearly' : 'Monthly',
                        style: TextStyle(
                          color: p.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Icon(
                      selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_off,
                      color: selected ? p.accent : p.textSecondary,
                      size: 18,
                    ),
                  ],
                ),
                if (savings != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      'Save $savings% vs monthly',
                      style: TextStyle(
                        color: p.textPrimary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                const SizedBox(height: 14),
                Text(
                  product.price,
                  style: TextStyle(
                    color: p.textPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  product.isYearly ? 'per year' : 'per month',
                  style: TextStyle(color: p.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
