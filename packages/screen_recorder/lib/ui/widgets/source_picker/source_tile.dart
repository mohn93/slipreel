import 'dart:typed_data';
import 'package:flutter/material.dart';

class SourceTile extends StatelessWidget {
  const SourceTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.thumbnail,
    required this.isSelected,
    required this.isErrored,
    required this.fallbackIcon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final Uint8List? thumbnail;
  final bool isSelected;
  final bool isErrored;
  final IconData fallbackIcon;
  final VoidCallback onTap;

  static const Color _selectionColor = Color(0xFF6C63FF);

  @override
  Widget build(BuildContext context) {
    final borderColor = isSelected ? _selectionColor : Colors.white12;
    final borderWidth = isSelected ? 2.0 : 1.0;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          key: const ValueKey('source-tile-outer'),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isSelected ? Colors.white12 : Colors.white10,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor, width: borderWidth),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: _buildThumbnail(),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6), fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail() {
    if (isErrored || thumbnail == null) {
      return Container(
        color: Colors.white10,
        child: Center(
          child: Icon(fallbackIcon, color: Colors.white38, size: 32),
        ),
      );
    }
    return Image.memory(thumbnail!, fit: BoxFit.cover, gaplessPlayback: true);
  }
}
