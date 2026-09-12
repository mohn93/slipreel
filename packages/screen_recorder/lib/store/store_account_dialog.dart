import '../ui/theme/app_palette_context.dart';
import '../licensing/entitlement.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../licensing/licensing_controller.dart';
import '../ui/widgets/desktop_dialog.dart';
import 'native_account.dart';

class StoreAccountDialog extends ConsumerStatefulWidget {
  const StoreAccountDialog({super.key});
  @override
  ConsumerState<StoreAccountDialog> createState() => _StoreAccountDialogState();
}

class _StoreAccountDialogState extends ConsumerState<StoreAccountDialog> {
  final _email = TextEditingController(), _code = TextEditingController();
  bool _busy = false;
  String? _challenge, _message;
  @override
  void initState() {
    super.initState();
    Future.microtask(() => _run(() => ref.read(nativeAccountProvider).load()));
  }

  @override
  void dispose() {
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool close = false,
    String? success,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
      if (mounted && close) Navigator.pop(context, true);
      if (mounted && !close) setState(() => _message = success);
    } catch (e) {
      if (mounted) {
        setState(
          () => _message = e is AccountError
              ? e.message
              : 'Could not complete this request. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(nativeAccountProvider);
    final access = ref.watch(entitlementProvider);
    final applePurchase =
        access is EntitlementAppStore && access.productId != null;
    final palette = context.palette;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DesktopDialogHeading(
            title: account.signedIn ? 'Account' : 'Sign in to Slipreel',
          ),
          const SizedBox(height: 12),
          if (account.signedIn) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: palette.accentMuted,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    Icons.person_outline_rounded,
                    color: palette.accent,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        account.email!,
                        style: TextStyle(
                          color: palette.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Signed in on this Mac',
                        style: TextStyle(
                          color: palette.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Divider(color: palette.dividerStrong, height: 1),
            const SizedBox(height: 8),
            _AccountAction(
              icon: Icons.sync_rounded,
              title: 'Sync purchases and access',
              subtitle: 'Refresh access linked to your account.',
              onTap: _busy
                  ? null
                  : () => _run(
                      account.syncPurchases,
                      success: 'Your purchases and access are up to date.',
                    ),
            ),
            if (applePurchase)
              _AccountAction(
                icon: Icons.credit_card_rounded,
                title: 'Manage subscription',
                subtitle: 'View your Apple subscription options.',
                onTap: _busy
                    ? null
                    : () => _run(
                        () => ref
                            .read(licensingControllerProvider.notifier)
                            .appStore!
                            .manageSubscriptions(),
                      ),
              ),
            const SizedBox(height: 8),
            Divider(color: palette.dividerStrong, height: 1),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 16,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.logout_rounded, size: 16),
                  onPressed: _busy ? null : () => _run(account.signOut),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: palette.textPrimary,
                    side: BorderSide(color: palette.dividerStrong),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 16,
                    ),
                  ),
                  label: const Text('Sign out'),
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                  onPressed: _busy
                      ? null
                      : () async {
                          final confirmed = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: const Text(
                                'Delete your Slipreel account?',
                              ),
                              content: const Text(
                                'This permanently deletes your account and shared access. Website subscriptions will be cancelled. Apple subscriptions must be cancelled separately in your Apple Account settings; deleting your Slipreel account does not cancel Apple billing. Local recordings remain on this Mac.',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Keep account'),
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx, true),
                                  child: const Text('Delete account'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true && mounted) {
                            await _run(account.deleteAccount);
                          }
                        },
                  child: const Text('Delete account'),
                ),
              ],
            ),
          ] else ...[
            const Text(
              'Use the same account as your existing purchase to share access. Recording and editing do not require an account.',
            ),
            const SizedBox(height: 16),
            if (_challenge == null) ...[
              TextField(
                controller: _email,
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                autofillHints: const [AutofillHints.email],
                decoration: const InputDecoration(
                  labelText: 'Email address',
                  hintText: 'you@example.com',
                  prefixIcon: Icon(Icons.mail_outline_rounded),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        if (!RegExp(
                          r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
                        ).hasMatch(_email.text.trim())) {
                          throw const AccountError(
                            'Enter a valid email address to receive your code.',
                          );
                        }
                        _challenge = await account.sendCode(_email.text);
                      }),
                child: const Text('Email me a sign-in code'),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.apple),
                style: OutlinedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                onPressed: _busy
                    ? null
                    : () => _run(account.signInWithApple, close: true),
                label: const Text('Sign in with Apple'),
              ),
              const Text(
                'If you previously used email sign-in, choose that same address. Apple’s Hide My Email may create a separate account.',
              ),
            ] else ...[
              Text('Enter the 8-digit code sent to ${_email.text.trim()}.'),
              TextField(
                controller: _code,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                autofillHints: const [AutofillHints.oneTimeCode],
                maxLength: 8,
                decoration: const InputDecoration(
                  labelText: 'Sign-in code',
                  border: OutlineInputBorder(),
                ),
              ),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(
                        () => account.verifyCode(_challenge!, _code.text),
                        close: true,
                      ),
                child: const Text('Sign in'),
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() => _challenge = null),
                child: const Text('Use another email or request a new code'),
              ),
            ],
          ],
          if (_busy) const LinearProgressIndicator(),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _message!,
                  style: TextStyle(color: palette.textSecondary, height: 1.5),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Full-row targets keep account actions readable and easy to scan.
class _AccountAction extends StatelessWidget {
  const _AccountAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: TextButton(
        onPressed: onTap,
        style: TextButton.styleFrom(
          foregroundColor: palette.textPrimary,
          disabledForegroundColor: palette.textSecondary,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.centerLeft,
        ),
        child: Row(
          children: [
            Icon(icon, size: 21, color: palette.textSecondary),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: palette.textSecondary,
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: palette.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
