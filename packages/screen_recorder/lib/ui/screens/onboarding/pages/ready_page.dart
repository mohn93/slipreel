import 'package:flutter/material.dart';

class ReadyPage extends StatelessWidget {
  const ReadyPage({super.key, required this.onFinish});
  final VoidCallback onFinish;
  @override
  Widget build(BuildContext context) =>
      const Center(child: Text('Ready (stub)'));
}
