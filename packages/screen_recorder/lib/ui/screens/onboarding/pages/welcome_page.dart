import 'package:flutter/material.dart';

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key, required this.onNext});
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 48),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Spacer(),
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Icon(Icons.videocam,
                size: 56, color: theme.colorScheme.primary),
          ),
          const SizedBox(height: 32),
          Text('Welcome to Slipreel',
              style: theme.textTheme.displaySmall),
          const SizedBox(height: 12),
          Text(
            'Polished screen recordings with smart defaults.',
            style: theme.textTheme.titleMedium
                ?.copyWith(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
          const Spacer(),
          SizedBox(
            width: 240,
            child: FilledButton(
              onPressed: onNext,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Get started'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
