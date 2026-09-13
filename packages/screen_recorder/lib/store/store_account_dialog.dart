import '../ui/theme/app_palette_context.dart';
import '../licensing/entitlement.dart';
import '../licensing/build_release_date.g.dart';
import '../licensing/export_gate.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  ButtonStyle get _primaryStyle => FilledButton.styleFrom(
    minimumSize: const Size.fromHeight(48),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
  );

  InputDecoration _fieldDecoration(String hint) {
    final p = context.palette;
    return InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(color: p.textSecondary),
      filled: true,
      fillColor: p.surfaceCard,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 17),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: p.dividerStrong),
      ),
    );
  }

  Future<void> _sendCode(NativeAccount account) => _run(() async {
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(_email.text.trim())) {
      throw const AccountError(
        'Enter a valid email address to receive your code.',
      );
    }
    _challenge = await account.sendCode(_email.text.trim());
  });

  Future<void> _verifyCode(NativeAccount account) => _run(() async {
    if (!RegExp(r'^\d{8}$').hasMatch(_code.text)) {
      throw const AccountError('Enter the 8-digit code from your email.');
    }
    await account.verifyCode(_challenge!, _code.text);
  }, close: true);

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
            title: account.signedIn ? 'Account' : 'Slipreel',
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
              title: 'Restore purchases',
              subtitle: 'Recover a purchase that isn’t showing up.',
              onTap: _busy
                  ? null
                  : () => _run(() async {
                      final controller = ref.read(
                        licensingControllerProvider.notifier,
                      );
                      await controller.appStore!.restore();
                      await account.syncPurchases();
                      await controller.refreshNow();
                      if (!canExportNow(
                        ref.read(entitlementProvider),
                        appReleaseDate: buildReleaseDate,
                      )) {
                        throw const AccountError(
                          'No active purchase found. Check your Apple Account or sign in to the Slipreel account used for your purchase.',
                        );
                      }
                    }, success: 'Your purchases and access are up to date.'),
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
            const SizedBox(height: 8),
            Text(
              _challenge == null
                  ? 'Your next great video starts here.'
                  : 'Check your inbox',
              style: TextStyle(
                color: palette.textPrimary,
                fontSize: 26,
                fontWeight: FontWeight.w600,
                height: 1.2,
                letterSpacing: -0.6,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _challenge == null
                  ? 'Sign in to keep your Pro access with you on every Mac.'
                  : 'We sent an 8-digit sign-in code to ${_email.text.trim()}.',
              style: TextStyle(
                color: palette.textSecondary,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 26),
            if (_challenge == null) ...[
              OutlinedButton.icon(
                icon: const Icon(Icons.apple, size: 23),
                style: OutlinedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: Colors.black,
                  disabledForegroundColor: Colors.black45,
                  minimumSize: const Size.fromHeight(48),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                onPressed: _busy
                    ? null
                    : () => _run(account.signInWithApple, close: true),
                label: const Text('Sign in with Apple'),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(child: Divider(color: palette.dividerStrong)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Text(
                      'or use email',
                      style: TextStyle(
                        color: palette.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  Expanded(child: Divider(color: palette.dividerStrong)),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                'Email address',
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _email,
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.email],
                onSubmitted: (_) => _sendCode(account),
                style: const TextStyle(fontSize: 14),
                decoration: _fieldDecoration('you@example.com'),
              ),
              const SizedBox(height: 12),
              FilledButton(
                style: _primaryStyle,
                onPressed: _busy ? null : () => _sendCode(account),
                child: const Text('Continue with email'),
              ),
              const SizedBox(height: 22),
              Text(
                'Already have Pro? Use your original sign-in method.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Recording and editing are free. No account needed.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: palette.textSecondary,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
            ] else ...[
              TextField(
                controller: _code,
                enabled: !_busy,
                autofocus: true,
                keyboardType: TextInputType.number,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.oneTimeCode],
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(8),
                ],
                onSubmitted: (_) => _verifyCode(account),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 24,
                  letterSpacing: 6,
                  fontWeight: FontWeight.w600,
                ),
                decoration: _fieldDecoration(
                  '00000000',
                ).copyWith(labelText: 'Sign-in code'),
              ),
              const SizedBox(height: 16),
              FilledButton(
                style: _primaryStyle,
                onPressed: _busy ? null : () => _verifyCode(account),
                child: const Text('Sign in'),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _challenge = null;
                        _code.clear();
                        _message = null;
                      }),
                child: const Text('Change email or send a new code'),
              ),
            ],
          ],
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: LinearProgressIndicator(minHeight: 2),
            ),
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
