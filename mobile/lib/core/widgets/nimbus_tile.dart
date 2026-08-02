import 'package:flutter/material.dart';

import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';
import 'nimbus_card.dart';

/// Grid-view tile for a folder or a file.
///
/// The counterpart to `NimbusListRow`. A drive needs both: list for scanning
/// names and dates, grid for recognising images. They share their colour
/// mapping through `tokens.accentForType` so a video is the same lilac either
/// way.
class NimbusTile extends StatelessWidget {
  const NimbusTile({
    super.key,
    required this.title,
    required this.icon,
    this.subtitle,
    this.accent,
    this.thumbnail,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.badge,
  });

  final String title;
  final IconData icon;
  final String? subtitle;
  final Color? accent;

  /// Replaces the icon block for image and video files. Filled edge to edge —
  /// a thumbnail with padding around it reads as a placeholder.
  final Widget? thumbnail;

  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Corner marker: a lock for encrypted, a link for shared.
  final IconData? badge;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final tint = accent ?? tokens.textSecondary;

    return NimbusCard(
      onTap: onTap,
      padding: const EdgeInsets.all(Gap.sm),
      radius: Radii.md,
      color: selected ? tokens.raisedHigh : tokens.raised,
      bordered: selected,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: 1.35,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(Radii.sm),
                  child: thumbnail == null
                      ? ColoredBox(
                          color: tint.withValues(alpha: 0.16),
                          child: Icon(icon, size: 28, color: tint),
                        )
                      : FittedBox(fit: BoxFit.cover, child: thumbnail),
                ),
                if (badge != null)
                  Positioned(
                    top: Gap.xxs,
                    right: Gap.xxs,
                    child: Container(
                      padding: const EdgeInsets.all(Gap.xxs),
                      decoration: BoxDecoration(
                        color: tokens.canvas.withValues(alpha: 0.7),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(badge, size: 12, color: tokens.textPrimary),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: Gap.xs),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.text.bodyMedium!.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
          if (subtitle != null)
            Text(
              subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.bodySmall!.copyWith(
                color: tokens.textTertiary,
              ),
            ),
        ],
      ),
    );
  }
}
