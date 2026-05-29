import 'package:flutter/material.dart';

import '../../state/recovery_service.dart';

class RecoveryModal extends StatefulWidget {
  const RecoveryModal({
    super.key,
    required this.candidates,
    required this.onRecover,
    required this.onDiscard,
  });

  final List<RecoveryCandidate> candidates;
  final Future<String?> Function(RecoveryCandidate) onRecover;
  final Future<void> Function(RecoveryCandidate) onDiscard;

  static const _visibleLimit = 5;

  @override
  State<RecoveryModal> createState() => _RecoveryModalState();
}

class _RecoveryModalState extends State<RecoveryModal> {
  late List<RecoveryCandidate> _remaining;
  final Set<String> _busy = {};
  final Map<String, String> _done = {}; // id → 'Recovered' | "Couldn't recover"

  @override
  void initState() {
    super.initState();
    _remaining = List.of(widget.candidates);
  }

  Future<void> _recover(RecoveryCandidate c) async {
    setState(() => _busy.add(c.marker.id));
    try {
      final out = await widget.onRecover(c);
      setState(() {
        _busy.remove(c.marker.id);
        _done[c.marker.id] = out != null ? 'Recovered' : "Couldn't recover";
      });
    } catch (_) {
      setState(() {
        _busy.remove(c.marker.id);
        _done[c.marker.id] = "Couldn't recover";
      });
    }
  }

  Future<void> _discard(RecoveryCandidate c) async {
    setState(() => _busy.add(c.marker.id));
    await widget.onDiscard(c);
    setState(() {
      _busy.remove(c.marker.id);
      _remaining.removeWhere((x) => x.marker.id == c.marker.id);
    });
  }

  Future<void> _discardAll() async {
    final batch = List.of(_remaining);
    for (final c in batch) {
      await widget.onDiscard(c);
    }
    setState(() => _remaining.clear());
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _remaining.take(RecoveryModal._visibleLimit).toList();
    final overflow = _remaining.length - visible.length;
    return AlertDialog(
      title: const Text('Recover unfinished recordings?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              "Slipreel didn't shut down cleanly. We found recordings that "
              'were still being captured.',
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final c in visible) _row(c),
                    if (overflow > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          '+ $overflow older',
                          style: const TextStyle(color: Colors.white54),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _remaining.isEmpty ? null : _discardAll,
          child: const Text('Discard all'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('Close'),
        ),
      ],
    );
  }

  Widget _row(RecoveryCandidate c) {
    final id = c.marker.id;
    final busy = _busy.contains(id);
    final done = _done[id];
    final label = '${c.marker.startedAt.toLocal()} · ${c.marker.fps} fps'
        '${c.marker.width > 0 ? ' · ${c.marker.width}×${c.marker.height}' : ''}';
    // Wrap in a keyless SizedBox so siblings in the Column have no key
    // conflict; the inner Padding carries the stable 'recovery-row' key that
    // tests locate via find.byKey.
    return SizedBox(
      child: Padding(
        key: const Key('recovery-row'),
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(child: Text(label)),
            if (busy)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (done != null)
              Text(done, style: const TextStyle(color: Colors.white70))
            else ...[
              TextButton(
                onPressed: () => _recover(c),
                child: const Text('Recover'),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: () => _discard(c),
                child: const Text('Discard'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
