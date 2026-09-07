import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/state/editor_look.dart';

import 'package:screen_recorder/analytics/analytics_events.dart';
import 'package:screen_recorder/analytics/analytics_service.dart';
import 'package:screen_recorder/state/look_template.dart';
import 'package:screen_recorder/state/look_template_controller.dart';
import 'package:screen_recorder/ui/app_alerts/app_alerts.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

enum _Action { saveNew, update, duplicate, rename, delete }

const _kMenuShape =
    RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(8)));

Text _menuText(String s, {Color color = Colors.white}) => Text(s,
    style: TextStyle(color: color, fontSize: 13),
    overflow: TextOverflow.ellipsis);

/// Row above the inspector's tab strip: pick a look template (applying it
/// immediately, with an undo toast owned by the caller) and manage
/// templates — save as new, update, duplicate, rename, delete — via an
/// overflow menu.
///
/// Decoupled from the playback screen's project controller: applying and
/// snapshotting the current look are passed in as callbacks so this widget
/// only depends on [lookTemplateControllerProvider].
class TemplateRow extends ConsumerWidget {
  const TemplateRow({
    super.key,
    required this.onApply,
    required this.currentLook,
  });

  /// Applies a look to the live project. Owned by the playback screen,
  /// which alone has the project controller and undo history.
  final void Function(EditorLook look) onApply;

  /// Snapshots the current project's look for save/update.
  final EditorLook Function() currentLook;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(lookTemplateControllerProvider);
    final selected = state.selected;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: _TemplatePicker(
              state: state,
              onSelect: (id) {
                ref.read(lookTemplateControllerProvider.notifier).select(id);
                onApply(ref.read(lookTemplateControllerProvider).selected.look);
              },
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<_Action>(
            key: const Key('template-overflow'),
            tooltip: 'Template actions',
            shape: _kMenuShape,
            color: kInspectorPanel,
            icon: const Icon(Icons.more_horiz, size: 18, color: kInspectorMuted),
            onSelected: (a) => _handleAction(context, ref, a, selected),
            itemBuilder: (context) => [
              PopupMenuItem(
                  value: _Action.saveNew,
                  child: _menuText('Save as new template…')),
              if (!selected.builtIn)
                PopupMenuItem(
                    value: _Action.update,
                    child: _menuText('Update "${selected.name}"')),
              PopupMenuItem(
                  value: _Action.duplicate, child: _menuText('Duplicate')),
              if (!selected.builtIn) ...[
                PopupMenuItem(
                    value: _Action.rename, child: _menuText('Rename…')),
                const PopupMenuDivider(height: 1),
                PopupMenuItem(
                    value: _Action.delete,
                    child: _menuText('Delete…', color: Colors.redAccent)),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _handleAction(
    BuildContext context,
    WidgetRef ref,
    _Action action,
    LookTemplate selected,
  ) async {
    final notifier = ref.read(lookTemplateControllerProvider.notifier);
    switch (action) {
      case _Action.saveNew:
        final name = await _promptForName(context,
            title: 'Save as new template', confirmLabel: 'Save');
        if (name == null) return;
        final t = await notifier.saveNew(name, currentLook());
        onApply(t.look);
        ref.captureAnalytics(AnalyticsEvents.templateSaved,
            properties: {'kind': 'new'});
        AppAlerts.success('Saved as "${t.name}".');
      case _Action.update:
        await notifier.update(selected.id, currentLook());
        ref.captureAnalytics(AnalyticsEvents.templateSaved,
            properties: {'kind': 'update'});
        AppAlerts.success('Template updated.');
      case _Action.duplicate:
        final t = await notifier.duplicate(selected.id);
        onApply(t.look);
        AppAlerts.success('Duplicated as "${t.name}".');
      case _Action.rename:
        final name = await _promptForName(context,
            title: 'Rename template',
            initialValue: selected.name,
            confirmLabel: 'Rename');
        if (name == null) return;
        await notifier.rename(selected.id, name);
      case _Action.delete:
        if (!await _confirmDelete(context, selected.name)) return;
        await notifier.delete(selected.id);
        ref.captureAnalytics(AnalyticsEvents.templateDeleted);
        AppAlerts.success('Deleted "${selected.name}".');
    }
  }
}

/// The template dropdown: current selection with a checkmarked list of
/// every template (built-ins first, then user templates by name).
class _TemplatePicker extends StatelessWidget {
  const _TemplatePicker({required this.state, required this.onSelect});

  final LookTemplatesState state;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final selected = state.selected;
    return PopupMenuButton<String>(
      key: const Key('template-select'),
      tooltip: '',
      shape: _kMenuShape,
      color: kInspectorPanel,
      onSelected: onSelect,
      itemBuilder: (context) => [
        for (final t in state.all)
          PopupMenuItem<String>(
            value: t.id,
            child: Row(children: [
              SizedBox(
                  width: 20,
                  child: t.id == selected.id
                      ? const Icon(Icons.check, size: 14, color: kInspectorAccent)
                      : null),
              Expanded(child: _menuText(t.name)),
            ]),
          ),
      ],
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: kInspectorPanel,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: kInspectorBorder),
        ),
        child: Row(children: [
          const Icon(Icons.style_outlined, size: 14, color: kInspectorMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(selected.name,
                style: const TextStyle(
                    color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis),
          ),
          const Icon(Icons.expand_more, size: 16, color: kInspectorMuted),
        ]),
      ),
    );
  }
}

/// Shared dark-themed dialog chrome for the name prompt and delete confirm.
Future<T?> _showTemplateDialog<T>(
  BuildContext context, {
  required Widget title,
  required Widget content,
  required List<Widget> actions,
}) =>
    showDialog<T>(
      context: context,
      barrierDismissible: true,
      builder: (_) => AlertDialog(
        backgroundColor: kInspectorPanel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: kInspectorBorder),
        ),
        title: title,
        content: content,
        actions: actions,
      ),
    );

Widget _cancelButton(BuildContext context, [Object? result]) => TextButton(
    onPressed: () => Navigator.pop(context, result),
    child: const Text('Cancel', style: TextStyle(color: kInspectorMuted)));

// [result] is a getter (not a value) so it's read at press-time — the
// name-prompt dialog's confirm button must read the live text field value.
Widget _primaryButton(BuildContext context, String label, Object? Function() result,
        {Color color = kInspectorAccent}) =>
    ElevatedButton(
      onPressed: () => Navigator.pop(context, result()),
      style:
          ElevatedButton.styleFrom(backgroundColor: color, foregroundColor: Colors.white),
      child: Text(label),
    );

/// Name-prompt dialog shared by "Save as new" and "Rename".
Future<String?> _promptForName(
  BuildContext context, {
  required String title,
  String initialValue = '',
  required String confirmLabel,
}) async {
  final controller = TextEditingController(text: initialValue);
  try {
    final result = await _showTemplateDialog<String>(
      context,
      title: Text(title, style: const TextStyle(color: Colors.white)),
      content: TextField(
        controller: controller,
        autofocus: true,
        style: const TextStyle(color: Colors.white),
        decoration: const InputDecoration(
          hintText: 'Template name',
          hintStyle: TextStyle(color: kInspectorMuted),
          enabledBorder:
              UnderlineInputBorder(borderSide: BorderSide(color: kInspectorBorder)),
          focusedBorder:
              UnderlineInputBorder(borderSide: BorderSide(color: kInspectorAccent)),
        ),
        onSubmitted: (v) => Navigator.pop(context, v.trim()),
      ),
      actions: [
        _cancelButton(context),
        _primaryButton(context, confirmLabel, () => controller.text.trim()),
      ],
    );
    return (result == null || result.isEmpty) ? null : result;
  } finally {
    controller.dispose();
  }
}

/// Destructive confirmation before deleting a user template.
Future<bool> _confirmDelete(BuildContext context, String name) async {
  final confirmed = await _showTemplateDialog<bool>(
    context,
    title: const Text('Delete this template?', style: TextStyle(color: Colors.white)),
    content: Text('"$name" will be permanently removed. This can\'t be undone.',
        style: const TextStyle(color: kInspectorMuted, fontSize: 14)),
    actions: [
      _cancelButton(context, false),
      _primaryButton(context, 'Delete', () => true, color: Colors.red.shade700),
    ],
  );
  return confirmed ?? false;
}
