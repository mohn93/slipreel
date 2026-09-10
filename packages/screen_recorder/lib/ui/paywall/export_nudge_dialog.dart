import 'package:screen_recorder/ui/widgets/desktop_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:screen_recorder/licensing/licensing_controller.dart';
import 'package:screen_recorder/ui/app_alerts/app_alerts.dart';
import 'package:screen_recorder/ui/theme/app_palette_context.dart';

/// A soft, skippable upsell shown once, after a not-yet-licensed user's first
/// successful export. It reinforces the value they just got and offers the
/// purchase path — it is NOT a paywall: dismissing it costs nothing and the
/// remaining free exports stay available. The gate proper is [PaywallDialog],
/// shown only when the trial is exhausted.
class ExportNudgeDialog {
  const ExportNudgeDialog._();

  static Future<void> show(BuildContext context, {required int remaining}) {
    return showDesktopDialog<void>(
      context: context,
      builder: (_) => _ExportNudgeBody(remaining: remaining),
    );
  }
}

class _ExportNudgeBody extends ConsumerStatefulWidget {
  const _ExportNudgeBody({required this.remaining});
  final int remaining;

  @override
  ConsumerState<_ExportNudgeBody> createState() => _ExportNudgeBodyState();
}

class _ExportNudgeBodyState extends ConsumerState<_ExportNudgeBody> {
  bool _busy = false;

  Future<void> _seePlans() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final ok = await ref
          .read(licensingControllerProvider.notifier)
          .unlockExport();
      if (!mounted) return;
      if (ok) {
        await Navigator.of(context).maybePop();
      } else {
        AppAlerts.error('Could not open the browser. Try again.');
      }
    } catch (_) {
      if (mounted) AppAlerts.error('Could not open plans on this device.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final left = widget.remaining;
    final body = left > 0
        ? 'Recording and editing are always free. You have $left free '
              "export${left == 1 ? '' : 's'} left — unlock unlimited exports "
              "whenever you're ready."
        : 'Recording and editing are always free. Unlock unlimited exports '
              "whenever you're ready.";
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const DesktopDialogHeading(
              title: 'Nice — your first export is done',
            ),
            const SizedBox(height: 12),
            Text(
              body,
              style: TextStyle(color: palette.textSecondary, height: 1.4),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _busy ? null : _seePlans,
              style: ElevatedButton.styleFrom(
                backgroundColor: palette.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: _busy
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('See plans'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
              child: Text(
                'Maybe later',
                style: TextStyle(color: palette.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
