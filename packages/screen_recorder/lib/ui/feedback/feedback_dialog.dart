import 'package:screen_recorder/ui/widgets/desktop_dialog.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../feedback/feedback_service.dart';
import '../app_alerts/app_alerts.dart';
import '../theme/app_palette.dart';
import '../theme/app_palette_context.dart';

/// In-app feedback with acknowledged delivery, durable offline queue status,
/// and an email fallback when delivery or local persistence is unavailable.
class FeedbackDialog {
  const FeedbackDialog._();

  static Future<void> show(BuildContext context) => showDesktopDialog<void>(
    context: context,
    builder: (_) => const _FeedbackBody(),
  );
}

class _FeedbackBody extends ConsumerStatefulWidget {
  const _FeedbackBody();

  @override
  ConsumerState<_FeedbackBody> createState() => _FeedbackBodyState();
}

class _FeedbackBodyState extends ConsumerState<_FeedbackBody> {
  bool _busy = false;
  bool _sendError = false;
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

  Future<void> _send() async {
    if (_busy) return;
    final message = _messageController.text.trim();
    if (message.isEmpty) return;
    setState(() => _busy = true);
    final email = _emailController.text.trim();
    DeliveryStatus result;
    try {
      result = await ref
          .read(feedbackServiceProvider)
          .submit(
            FeedbackReport(
              type: _type,
              message: message,
              email: email.isEmpty ? null : email,
              attachDiagnostics: _attachDiagnostics,
            ),
          );
    } catch (_) {
      result = DeliveryStatus.unavailable;
    }
    if (!mounted) return;
    if (result == DeliveryStatus.unavailable) {
      setState(() {
        _busy = false;
        _sendError = true;
      });
      return;
    }
    Navigator.of(context).pop();
    if (result == DeliveryStatus.sent) {
      AppAlerts.success('Thanks — feedback sent.');
    } else {
      AppAlerts.info(
        'Feedback saved on this Mac. We’ll send it when connected.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // Reflects emptiness for the button's look, but Send itself always stays
    // tappable and re-checks the live text at press time (see _send) — the
    // TextField's own onChanged notification lands via a listener rebuild
    // that a real user's next keystroke/frame always catches up with, so a
    // visually-gated onPressed would only ever *lag* one interaction behind,
    // never actually block a genuinely empty submission.
    final canSend = _messageController.text.trim().isNotEmpty;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const DesktopDialogHeading(title: 'Send feedback'),
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
                title: Text(
                  'Attach diagnostics',
                  style: TextStyle(color: palette.textPrimary),
                ),
                subtitle: Text(
                  'Includes app version, OS, and recent activity logs — '
                  'no recordings or file paths.',
                  style: TextStyle(color: palette.textSecondary, fontSize: 12),
                ),
              ),
              if (_sendError)
                const Text(
                  'Could not send or save your feedback. Your message is still here. Try again or email hello@slipreel.app.',
                ),
              TextButton(
                onPressed: () async {
                  final opened = await launchUrl(
                    Uri(scheme: 'mailto', path: 'hello@slipreel.app'),
                  );
                  if (!opened) {
                    AppAlerts.info('Email hello@slipreel.app for help.');
                  }
                },
                child: const Text('Email support: hello@slipreel.app'),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: Text(
                      'Cancel',
                      style: TextStyle(color: palette.textSecondary),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Opacity(
                    opacity: canSend ? 1 : 0.5,
                    child: ElevatedButton(
                      onPressed: _busy ? null : _send,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: palette.accent,
                        foregroundColor: Colors.white,
                      ),
                      child: Text(_busy ? 'Sending…' : 'Send'),
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
