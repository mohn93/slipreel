import 'package:flutter/material.dart';
import 'package:screen_recorder/ui/widgets/export_dialog/_export_dialog_theme.dart';

const Color _kFieldBg = kBgUnselected;
const Color _kBorderColor = Color(0xFF35354A);

class ShareableLinkPanel extends StatelessWidget {
  const ShareableLinkPanel({
    super.key,
    required this.title,
    required this.isPrivate,
    required this.onTitleChanged,
    required this.onIsPrivateChanged,
  });

  final String title;
  final bool isPrivate;
  final ValueChanged<String> onTitleChanged;
  final ValueChanged<bool> onIsPrivateChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _TitleField(value: title, onChanged: onTitleChanged)),
        const SizedBox(width: 24),
        Expanded(
          child: _PrivateToggle(
            value: isPrivate,
            onChanged: onIsPrivateChanged,
          ),
        ),
      ],
    );
  }
}

class _TitleField extends StatefulWidget {
  const _TitleField({required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_TitleField> createState() => _TitleFieldState();
}

class _TitleFieldState extends State<_TitleField> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
    _focusNode = FocusNode();
  }

  @override
  void didUpdateWidget(_TitleField old) {
    super.didUpdateWidget(old);
    if (old.value == widget.value) return;
    if (_controller.text == widget.value) return;
    // Don't clobber the caret if the user is mid-edit; the parent's
    // value will catch up via the next onChanged.
    if (_focusNode.hasFocus) return;
    _controller.text = widget.value;
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Video title',
          style: TextStyle(
            color: kTextPrimary,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          key: const ValueKey('shareable_title_field'),
          controller: _controller,
          focusNode: _focusNode,
          onChanged: widget.onChanged,
          style: const TextStyle(color: kTextPrimary, fontSize: 13),
          decoration: InputDecoration(
            filled: true,
            fillColor: _kFieldBg,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(kSegmentRadius),
              borderSide: const BorderSide(color: _kBorderColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(kSegmentRadius),
              borderSide: const BorderSide(color: kAccent, width: 1.5),
            ),
          ),
        ),
      ],
    );
  }
}

class _PrivateToggle extends StatelessWidget {
  const _PrivateToggle({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Text(
              'Private',
              style: TextStyle(
                color: kTextPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const Spacer(),
            Switch(
              key: const ValueKey('shareable_private_switch'),
              value: value,
              onChanged: onChanged,
              activeThumbColor: kAccent,
            ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          'Only the people you share this video with will be able to watch it.',
          style: TextStyle(color: kTextSecondary, fontSize: 12),
        ),
      ],
    );
  }
}
