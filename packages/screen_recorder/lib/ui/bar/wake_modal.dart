import 'dart:async';

import 'package:flutter/material.dart';

class WakeModal extends StatefulWidget {
  const WakeModal({
    super.key,
    required this.title,
    required this.body,
    required this.primaryLabel,
    required this.secondaryLabel,
    required this.autoStopAfter,
    required this.onPrimary,
    required this.onSecondary,
  });

  final String title;
  final String body;
  final String primaryLabel;
  final String secondaryLabel;
  final Duration autoStopAfter;
  final VoidCallback onPrimary;
  final VoidCallback onSecondary;

  @override
  State<WakeModal> createState() => _WakeModalState();
}

class _WakeModalState extends State<WakeModal> {
  Timer? _autoTimer;
  late int _remainingSec;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _remainingSec = widget.autoStopAfter.inSeconds;
    _autoTimer = Timer(widget.autoStopAfter, () {
      if (mounted) widget.onSecondary();
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _remainingSec = (_remainingSec - 1).clamp(0, 1 << 30));
    });
  }

  @override
  void dispose() {
    _autoTimer?.cancel();
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title),
          if (_remainingSec > 0)
            Text(
              'Auto-stop in ${_remainingSec}s',
              style: const TextStyle(color: Colors.white54, fontSize: 12),
            ),
        ],
      ),
      content: Text(widget.body),
      actions: [
        TextButton(
            onPressed: () {
              _autoTimer?.cancel();
              widget.onSecondary();
            },
            child: Text(widget.secondaryLabel)),
        FilledButton(
            onPressed: () {
              _autoTimer?.cancel();
              widget.onPrimary();
            },
            child: Text(widget.primaryLabel)),
      ],
    );
  }
}
