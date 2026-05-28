import 'package:flutter/material.dart';

class ReadyPage extends StatelessWidget {
  const ReadyPage({super.key, required this.onFinish});
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 48),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Spacer(),
          const Icon(Icons.check_circle,
              color: Colors.greenAccent, size: 80),
          const SizedBox(height: 24),
          Text("You're all set",
              style: Theme.of(context).textTheme.displaySmall),
          const SizedBox(height: 12),
          Text(
            'Press the Display button on the recording bar to start.',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
          const Spacer(),
          SizedBox(
            width: 280,
            child: FilledButton(
              onPressed: onFinish,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Record my first video'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
