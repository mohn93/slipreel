import 'package:flutter/material.dart';

import 'required_update.dart';

class RequiredUpdateDialog extends StatefulWidget {
  const RequiredUpdateDialog({
    super.key,
    required this.update,
    required this.onUpdate,
  });
  final RequiredUpdate update;
  final Future<void> Function() onUpdate;

  @override
  State<RequiredUpdateDialog> createState() => _RequiredUpdateDialogState();
}

class _RequiredUpdateDialogState extends State<RequiredUpdateDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _update() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onUpdate();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not open the updater. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    child: AlertDialog(
      title: const Text('Update required'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Install Slipreel ${widget.update.version} to continue using the app. Your installed version is no longer supported.',
          ),
          const SizedBox(height: 12),
          const Text(
            'Choose Update now to open the installer. If you close it, you can try again here, or quit Slipreel with ⌘Q.',
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        FilledButton(
          onPressed: _busy ? null : _update,
          child: Text(_busy ? 'Opening updater…' : 'Update now'),
        ),
      ],
    ),
  );
}
