import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';
import 'pressable.dart';

/// Selectable filter pill — file type, tag, sort order.
///
/// Selection is animated rather than swapped so a row of chips settles into
/// its new state instead of flickering through it.
class NimbusChip extends StatelessWidget {
  const NimbusChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.icon,
    this.accent,
    this.count,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final IconData? icon;

  /// Tints the chip when selected. Used to carry a category colour through
  /// from the breakdown bar so a filter and its data agree visually.
  final Color? accent;

  /// Trailing count, shown muted.
  final int? count;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final tint = accent ?? AppColors.primary;

    final background = selected ? tint : tokens.raised;
    final foreground = selected ? AppColors.onPrimary : tokens.textSecondary;

    return Pressable(
      onTap: onTap,
      scale: 0.95,
      child: AnimatedContainer(
        duration: Motion.normal,
        curve: Motion.decelerate,
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.md,
          vertical: Gap.xs + 2,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: foreground),
              const SizedBox(width: Gap.xxs + 2),
            ],
            AnimatedDefaultTextStyle(
              duration: Motion.normal,
              curve: Motion.decelerate,
              style: context.text.labelLarge!.copyWith(color: foreground),
              child: Text(label),
            ),
            if (count != null) ...[
              const SizedBox(width: Gap.xs),
              Text(
                '$count',
                style: context.text.bodySmall!.copyWith(
                  color: foreground.withValues(alpha: 0.65),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
