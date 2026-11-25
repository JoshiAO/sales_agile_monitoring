import 'package:flutter/material.dart';

class UserAvatar extends StatelessWidget {
  final String? profilePicUrl;
  final String displayName;
  final double radius;
  final VoidCallback? onTap;
  final bool showEditBadge;

  const UserAvatar({
    super.key,
    required this.profilePicUrl,
    required this.displayName,
    this.radius = 22,
    this.onTap,
    this.showEditBadge = false,
  });

  String _initials() {
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) return '?';
    final parts = trimmed
        .split(RegExp(r'\s+'))
        .where((p) => p.isNotEmpty)
        .take(2)
        .toList();
    if (parts.isEmpty) return '?';
    return parts.map((p) => p[0].toUpperCase()).join();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final hasImage =
        profilePicUrl != null && profilePicUrl!.trim().isNotEmpty;
    final diameter = radius * 2;

    Widget avatar = Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: colorScheme.primaryContainer,
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.6),
          width: 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: hasImage
          ? Image.network(
              profilePicUrl!.trim(),
              fit: BoxFit.cover,
              width: diameter,
              height: diameter,
              errorBuilder: (_, _, _) => _buildInitials(colorScheme),
              loadingBuilder: (context, child, progress) {
                if (progress == null) return child;
                return Center(
                  child: SizedBox(
                    width: radius * 0.7,
                    height: radius * 0.7,
                    child: const CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              },
            )
          : _buildInitials(colorScheme),
    );

    if (showEditBadge) {
      avatar = Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: colorScheme.primary,
                shape: BoxShape.circle,
                border: Border.all(color: colorScheme.surface, width: 2),
              ),
              child: const Icon(
                Icons.camera_alt_rounded,
                size: 12,
                color: Colors.white,
              ),
            ),
          ),
        ],
      );
    }

    if (onTap != null) {
      return MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: onTap, child: avatar),
      );
    }

    return avatar;
  }

  Widget _buildInitials(ColorScheme colorScheme) {
    return Center(
      child: Text(
        _initials(),
        style: TextStyle(
          fontSize: radius * 0.72,
          fontWeight: FontWeight.w700,
          color: colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

