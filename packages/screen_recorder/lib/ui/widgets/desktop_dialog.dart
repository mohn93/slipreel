import 'package:flutter/material.dart';

/// A centered desktop surface with dialog focus traversal and Escape dismissal.
/// The body owns its scrolling so longer forms fit smaller windows.
Future<T?> showDesktopDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) => showDialog<T>(
  context: context,
  barrierColor: Colors.black.withValues(alpha: 0.6),
  builder: (context) => Dialog(
    alignment: Alignment.center,
    insetPadding: const EdgeInsets.all(24),
    clipBehavior: Clip.antiAlias,
    child: SizedBox(width: 520, child: builder(context)),
  ),
);

class DesktopDialogHeading extends StatelessWidget {
  const DesktopDialogHeading({super.key, required this.title});

  final String title;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Semantics(
          namesRoute: true,
          header: true,
          child: Text(
            title,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
      const SizedBox(width: 12),
      const CloseButton(),
    ],
  );
}
