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
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
      if (mounted && close) Navigator.pop(context, true);
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
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DesktopDialogHeading(
            title: account.signedIn
                ? 'Your Slipreel account'
                : 'Sign in to Slipreel',
          ),
          const SizedBox(height: 12),
          if (account.signedIn) ...[
            Text(account.email!),
            const SizedBox(height: 12),
            const Text(
              'Your account shares access between your Macs and Slipreel editions. Manage a subscription with the provider where you purchased it.',
            ),
            TextButton(
              onPressed: _busy ? null : () => _run(account.syncPurchases),
              child: const Text('Sync purchases and access'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () => _run(
                      () => ref
                          .read(licensingControllerProvider.notifier)
                          .appStore!
                          .manageSubscriptions(),
                    ),
              child: const Text('Manage Apple subscription'),
            ),
            TextButton(
              onPressed: _busy ? null : () => _run(account.signOut),
              child: const Text('Sign out'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('Delete your Slipreel account?'),
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
                decoration: const InputDecoration(labelText: 'Email address'),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                        _challenge = await account.sendCode(_email.text);
                      }),
                child: const Text('Email me a sign-in code'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(account.signInWithApple, close: true),
                child: const Text('Sign in with Apple'),
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
                decoration: const InputDecoration(labelText: 'Sign-in code'),
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
              child: Text(_message!),
            ),
        ],
      ),
    );
  }
}
