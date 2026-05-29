import 'dart:async';

import 'package:flutter/material.dart';

class RecordingToast {
  static OverlayEntry? _entry;
  static Timer? _dismiss;

  static void show(BuildContext context, String message, {IconData icon = Icons.info_outline}) {
    final overlay = Overlay.of(context, rootOverlay: true);
    _entry?.remove();
    _dismiss?.cancel();
    final entry = OverlayEntry(builder: (_) => _ToastWidget(message: message, icon: icon));
    _entry = entry;
    overlay.insert(entry);
    _dismiss = Timer(const Duration(seconds: 6), () {
      entry.remove();
      if (_entry == entry) _entry = null;
    });
  }
}

class _ToastWidget extends StatelessWidget {
  const _ToastWidget({required this.message, required this.icon});
  final String message;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      bottom: 24,
      left: 0,
      right: 0,
      child: Center(
        child: Material(
          color: const Color(0xFF2C2C30),
          elevation: 6,
          borderRadius: BorderRadius.circular(20),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text(message,
                  style:
                      const TextStyle(color: Colors.white, fontWeight: FontWeight.w500)),
            ]),
          ),
        ),
      ),
    );
  }
}
