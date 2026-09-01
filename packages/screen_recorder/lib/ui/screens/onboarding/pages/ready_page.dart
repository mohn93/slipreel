import 'package:flutter/material.dart';

class ReadyPage extends StatelessWidget {
  const ReadyPage({super.key, required this.onFinish});
  final VoidCallback onFinish;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        const _ReadyGlow(),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 48),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Spacer(),
              const _SuccessCheck(),
              const SizedBox(height: 28),
              Text("You're all set", style: theme.textTheme.displaySmall),
              const SizedBox(height: 12),
              Text(
                'Press the Display button on the recording bar to start.',
                style: theme.textTheme.titleMedium
                    ?.copyWith(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
              const Spacer(),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 440),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 16),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                  ),
                  child: const Column(
                    children: [
                      _ShortcutRow(
                        keys: ['⌘', '⇧', '1'],
                        label: 'Start recording from anywhere',
                      ),
                      SizedBox(height: 12),
                      _ShortcutRow(keys: ['⌘', '⇧', '2'], label: 'Stop'),
                      SizedBox(height: 12),
                      _ShortcutRow(
                        keys: ['⌘', '⇧', 'P'],
                        label: 'Pause / Resume',
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
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
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: Colors.white38),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A green success badge that springs and fades in when the page appears.
class _SuccessCheck extends StatefulWidget {
  const _SuccessCheck();

  @override
  State<_SuccessCheck> createState() => _SuccessCheckState();
}

class _SuccessCheckState extends State<_SuccessCheck>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
    )..forward();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _c, curve: Curves.elasticOut),
    );
    final fade = CurvedAnimation(
      parent: _c,
      curve: const Interval(0.0, 0.45, curve: Curves.easeOut),
    );
    return FadeTransition(
      opacity: fade,
      child: ScaleTransition(
        scale: scale,
        child: Container(
          width: 92,
          height: 92,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF34D399), Color(0xFF10B981)],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF10B981).withValues(alpha: 0.5),
                blurRadius: 44,
                spreadRadius: 2,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: const Icon(Icons.check_rounded, color: Colors.white, size: 52),
        ),
      ),
    );
  }
}

/// Soft success glow behind the badge, matching the welcome page's depth.
class _ReadyGlow extends StatelessWidget {
  const _ReadyGlow();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.45),
          radius: 0.9,
          colors: [Color(0x2610B981), Color(0x00000000)],
          stops: [0.0, 1.0],
        ),
      ),
    );
  }
}

class _ShortcutRow extends StatelessWidget {
  const _ShortcutRow({required this.keys, required this.label});
  final List<String> keys;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 108,
          child: Row(
            children: [for (final k in keys) _KeyCap(k)],
          ),
        ),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ),
      ],
    );
  }
}

/// A single keyboard-key cap.
class _KeyCap extends StatelessWidget {
  const _KeyCap(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 26),
      height: 26,
      alignment: Alignment.center,
      margin: const EdgeInsets.only(right: 5),
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.16),
            Colors.white.withValues(alpha: 0.06),
          ],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 3,
            offset: const Offset(0, 1.5),
          ),
        ],
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w600,
          height: 1.0,
        ),
      ),
    );
  }
}
