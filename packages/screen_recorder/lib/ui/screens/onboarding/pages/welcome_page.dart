import 'package:flutter/material.dart';

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key, required this.onNext});
  final VoidCallback onNext;
  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('Welcome (stub)'));
}
