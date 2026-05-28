import 'package:flutter/material.dart';

class PermissionsPage extends StatelessWidget {
  const PermissionsPage({super.key, required this.onNext});
  final VoidCallback onNext;
  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('Permissions (stub)'));
}
