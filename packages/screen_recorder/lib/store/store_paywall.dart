import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../licensing/licensing_controller.dart';
import '../licensing/export_gate.dart';
import '../licensing/build_release_date.g.dart';
import '../ui/widgets/desktop_dialog.dart';
import 'app_store_client.dart';
import 'native_account.dart';
import 'store_account_dialog.dart';

class StorePaywall extends ConsumerStatefulWidget {
  const StorePaywall({super.key});
  @override
  ConsumerState<StorePaywall> createState() => _StorePaywallState();
}

class _StorePaywallState extends ConsumerState<StorePaywall> {
  List<StoreProduct>? _products;
  bool _busy = false;
  String? _message;
  AppStoreClient get store =>
      ref.read(licensingControllerProvider.notifier).appStore!;
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
      final products = await store.products();
      if (mounted) {
        setState(() {
          _products = products;
          if (products.isEmpty) {
            _message = 'Plans are unavailable right now. Please try again.';
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _products = [];
          _message = 'Could not connect to the App Store.';
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
      if (canExportNow(
            ref.read(entitlementProvider),
            appReleaseDate: buildReleaseDate,
          ) &&
          message == null) {
        Navigator.pop(context, true);
      } else {
        setState(
          () => _message =
              message ??
              'No active subscription was found for this Apple Account.',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = e is AccountError
              ? e.message
              : 'The App Store could not complete this request. Please try again.',
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
    return account.signedIn;
  }

  @override
  Widget build(BuildContext context) {
    final entitled = canExportNow(
      ref.watch(entitlementProvider),
      appReleaseDate: buildReleaseDate,
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DesktopDialogHeading(
            title: entitled
                ? 'Unlimited exports are active'
                : 'Unlimited exports',
          ),
          const SizedBox(height: 12),
          Text(
            entitled
                ? 'Your current purchase already gives you access. You do not need another subscription.'
                : 'Record, edit, and preview for free. Subscribe to export as often as you like.',
          ),
          const SizedBox(height: 24),
          if (_products == null && !entitled)
            const Center(child: CircularProgressIndicator()),
          if (!entitled)
            for (final product in _products ?? <StoreProduct>[]) ...[
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _perform(() async {
                        if (!await _signIn()) {
                          return 'Sign in to link your subscription to your Slipreel account.';
                        }
                        // Sign-in may reveal an existing website purchase. Never double-charge.
                        if (canExportNow(
                          ref.read(entitlementProvider),
                          appReleaseDate: buildReleaseDate,
                        )) {
                          return null;
                        }
                        final result = await store.purchase(
                          product.id,
                          ref.read(nativeAccountProvider).appAccountToken!,
                        );
                        if (result == 'purchased') {
                          try {
                            await ref
                                .read(nativeAccountProvider)
                                .syncPurchases();
                          } catch (_) {
                            return 'Purchase completed. This Mac has access; account sync is pending. Use Sync purchases in your account to retry.';
                          }
                          return null;
                        }
                        return result == 'pending'
                            ? 'Waiting for Apple to approve the purchase. Access will update automatically.'
                            : 'Purchase cancelled. You have not been charged.';
                      }),
                child: Text(
                  'Subscribe · ${product.price} / ${product.period ?? 'month'}',
                ),
              ),
              const SizedBox(height: 8),
            ],
          if (_busy) const LinearProgressIndicator(),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_message!),
            ),
          if (_products?.isEmpty == true && !entitled)
            TextButton(
              onPressed: _busy ? null : _load,
              child: const Text('Retry'),
            ),
          if (!entitled)
            const Text(
              'Payment is charged to your Apple Account. The subscription renews automatically unless cancelled at least 24 hours before the current period ends. Manage or cancel in your Apple Account settings.',
            ),
          TextButton(
            onPressed: _busy
                ? null
                : () => _perform(() async {
                    await store.restore();
                    final account = ref.read(nativeAccountProvider);
                    await account.load();
                    if (account.signedIn) await account.syncPurchases();
                    return null;
                  }),
            child: const Text('Restore purchases'),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => _perform(() async {
                    await store.manageSubscriptions();
                    return '';
                  }),
            child: const Text('Manage Apple subscription'),
          ),
          TextButton(
            onPressed: _busy
                ? null
                : () => _perform(() async {
                    await _signIn();
                    return null;
                  }),
            child: const Text('Already have access? Sign in'),
          ),
          Wrap(
            alignment: WrapAlignment.center,
            children: [
              TextButton(
                onPressed: () =>
                    launchUrl(Uri.parse('https://slipreel.app/privacy')),
                child: const Text('Privacy policy'),
              ),
              TextButton(
                onPressed: () => launchUrl(
                  Uri.parse(
                    'https://www.apple.com/legal/internet-services/itunes/dev/stdeula/',
                  ),
                ),
                child: const Text('Terms of use'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
