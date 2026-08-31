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
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ShortcutRow(combo: '⌘⇧1', label: 'Start recording from anywhere'),
                SizedBox(height: 4),
                _ShortcutRow(combo: '⌘⇧2', label: 'Stop'),
                SizedBox(height: 4),
                _ShortcutRow(combo: '⌘⇧P', label: 'Pause / Resume'),
              ],
            ),
          ),
          const SizedBox(height: 16),
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
          const SizedBox(height: 16),
          Text(
            'Slipreel sends anonymous usage data to improve the app — never '
            'your recordings or screen contents. Turn it off anytime in '
            'Settings → Privacy.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: Colors.white38),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.combo, required this.label});
  final String combo;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      SizedBox(
          width: 60,
          child: Text(combo,
              style: const TextStyle(
                  color: Colors.white, fontFamily: 'Menlo', fontSize: 13))),
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
    ]);
  }
}
