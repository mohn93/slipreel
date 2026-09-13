import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'notification_controller.dart';

class NotificationSettings extends ConsumerWidget {
  const NotificationSettings({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(notificationControllerProvider);
    if (state == null) return const SizedBox.shrink();
    final enabled = state.permission == 'authorized';
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.notifications_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Stay in the loop',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    const Text('Service updates and messages from Slipreel.'),
                  ],
                ),
              ),
              if (!state.configured)
              const Text("Messages available in app")
            else if (enabled)
                const Chip(label: Text('Notifications enabled'))
              else
                FilledButton(
                  onPressed: state.busy ? null : state.enable,
                  child: Text(
                    state.permission == 'denied'
                        ? 'Open notification settings'
                        : 'Enable notifications',
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            icon: const Icon(Icons.inbox_outlined),
            label: Text(
              'Messages${state.messages.isEmpty ? '' : ' (${state.messages.length})'}',
            ),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const NotificationInbox(),
            ),
          ),
          if (state.policyMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(state.policyMessage!),
            ),
        ],
      ),
    );
  }
}

class NotificationInbox extends ConsumerWidget {
  const NotificationInbox({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(notificationControllerProvider);
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 580),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Messages',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (state?.error != null)
                Text(state!.error!)
              else if (state == null || state.messages.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Text(
                    'You’re all caught up. Messages from Slipreel will appear here.',
                  ),
                )
              else
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: state.messages.length,
                    separatorBuilder: (_, __) => const Divider(height: 32),
                    itemBuilder: (context, index) {
                      final message = state.messages[index];
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            message['title'] as String,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          SelectableText(message['body'] as String),
                        ],
                      );
                    },
                  ),
                ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: state?.sync,
                child: const Text('Check for messages'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
