import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../feedback/feedback_service.dart';
import '../app_alerts/app_alerts.dart';
import '../theme/app_palette.dart';

/// In-app feedback form: an idea/problem picker, a required message, an
/// optional email, and an opt-in diagnostics attachment. Submitting is
/// fire-and-forget from the UI's perspective — [FeedbackService] and its
/// sink absorb their own errors, so this never blocks or surfaces failures
/// to the user.
class FeedbackSheet {
  const FeedbackSheet._();

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => const _FeedbackBody(),
      );
}

class _FeedbackBody extends ConsumerStatefulWidget {
  const _FeedbackBody();

  @override
  ConsumerState<_FeedbackBody> createState() => _FeedbackBodyState();
}

class _FeedbackBodyState extends ConsumerState<_FeedbackBody> {
  FeedbackType _type = FeedbackType.problem;
  bool _attachDiagnostics = false;
  final _messageController = TextEditingController();
  final _emailController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _messageController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _messageController.dispose();
    _emailController.dispose();
    super.dispose();
  }

  void _send() {
    final message = _messageController.text.trim();
    if (message.isEmpty) return;
    final email = _emailController.text.trim();
    ref.read(feedbackServiceProvider).submit(FeedbackReport(
          type: _type,
          message: message,
          email: email.isEmpty ? null : email,
          attachDiagnostics: _attachDiagnostics,
        ));
    Navigator.of(context).maybePop();
    AppAlerts.success('Thanks — feedback sent.');
  }

  @override
  Widget build(BuildContext context) {
    // The app installs an AppPalette extension at the root (see main.dart),
    // so this is always populated in a real run. The fallback keeps this
    // sheet safe for hosts that don't set one up (e.g. minimal widget tests).
    final palette =
        Theme.of(context).extension<AppPalette>() ?? AppPalette.midnight;
    // Reflects emptiness for the button's look, but Send itself always stays
    // tappable and re-checks the live text at press time (see _send) — the
    // TextField's own onChanged notification lands via a listener rebuild
    // that a real user's next keystroke/frame always catches up with, so a
    // visually-gated onPressed would only ever *lag* one interaction behind,
    // never actually block a genuinely empty submission.
    final canSend = _messageController.text.trim().isNotEmpty;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
            24, 8, 24, 24 + MediaQuery.of(context).viewInsets.bottom),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Send feedback',
                style: TextStyle(
                  color: palette.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              _typeSelector(palette),
              const SizedBox(height: 16),
              TextField(
                controller: _messageController,
                minLines: 3,
                maxLines: 6,
                style: TextStyle(color: palette.textPrimary),
                decoration: InputDecoration(
                  labelText: _type == FeedbackType.problem
                      ? 'What went wrong?'
                      : "What's the idea?",
                  labelStyle: TextStyle(color: palette.textSecondary),
                  filled: true,
                  fillColor: palette.surfaceCard,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _emailController,
                style: TextStyle(color: palette.textPrimary),
                decoration: InputDecoration(
                  labelText: 'Email (optional — if you want a reply)',
                  labelStyle: TextStyle(color: palette.textSecondary),
                  filled: true,
                  fillColor: palette.surfaceCard,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _attachDiagnostics,
                onChanged: (v) =>
                    setState(() => _attachDiagnostics = v ?? false),
                title: Text('Attach diagnostics',
                    style: TextStyle(color: palette.textPrimary)),
                subtitle: Text(
                  'Includes app version, OS, and recent activity logs — '
                  'no recordings or file paths.',
                  style: TextStyle(color: palette.textSecondary, fontSize: 12),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text('Cancel',
                        style: TextStyle(color: palette.textSecondary)),
                  ),
                  const SizedBox(width: 8),
                  Opacity(
                    opacity: canSend ? 1 : 0.5,
                    child: ElevatedButton(
                      onPressed: _send,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: palette.accent,
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('Send'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _typeSelector(AppPalette palette) => SegmentedButton<FeedbackType>(
        segments: const [
          ButtonSegment(
            value: FeedbackType.idea,
            label: Text('Idea'),
            icon: Icon(Icons.lightbulb_outline),
          ),
          ButtonSegment(
            value: FeedbackType.problem,
            label: Text('Problem'),
            icon: Icon(Icons.bug_report_outlined),
          ),
        ],
        selected: {_type},
        onSelectionChanged: (s) => setState(() => _type = s.first),
      );
}
