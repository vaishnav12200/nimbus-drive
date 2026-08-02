import 'package:flutter/material.dart';

import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';
import 'pressable.dart';

/// A file, folder or transaction row.
///
/// The reference builds these without dividers or card backgrounds — rhythm
/// comes from the leading icon tile and consistent vertical spacing alone.
/// Adding a divider here would be the fastest way to make the app stop looking
/// like the reference.
class NimbusListRow extends StatelessWidget {
  const NimbusListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    this.iconColor,
    this.leading,
    this.trailing,
    this.trailingSubtitle,
    this.onTap,
    this.onLongPress,
    this.selected = false,
  });

  final String title;
  final String? subtitle;

  /// Painted inside a tinted rounded tile. Ignored when [leading] is given.
  final IconData? icon;

  /// Category colour. The icon takes it at full strength and the tile behind
  /// it at low alpha, which is what keeps six different accents on one screen
  /// from shouting.
  final Color? iconColor;

  /// Replaces the icon tile entirely — a thumbnail, an avatar, a checkbox.
  final Widget? leading;

  /// Primary trailing content. A plain [Text] is the common case.
  final Widget? trailing;

  /// Muted second line under [trailing], right-aligned.
  final String? trailingSubtitle;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final accent = iconColor ?? tokens.textSecondary;

    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      scale: 0.985,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.decelerate,
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.sm,
          vertical: Gap.sm - 2,
        ),
        decoration: BoxDecoration(
          color: selected ? tokens.raised : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        child: Row(
          children: [
            leading ??
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(Radii.sm),
                  ),
                  child: Icon(icon, size: 21, color: accent),
                ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.text.bodyLarge!.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodySmall!.copyWith(
                        color: tokens.textTertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null || trailingSubtitle != null) ...[
              const SizedBox(width: Gap.xs),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (trailing != null)
                    DefaultTextStyle.merge(
                      style: context.text.bodyLarge!.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      child: trailing!,
                    ),
                  if (trailingSubtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      trailingSubtitle!,
                      style: context.text.bodySmall!.copyWith(
                        color: tokens.textTertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// "Recent files ———— See all". The standard lead-in to a list.
class NimbusSectionHeader extends StatelessWidget {
  const NimbusSectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(title, style: context.text.titleLarge),
        if (actionLabel != null)
          Pressable(
            onTap: onAction,
            scale: 0.95,
            child: Padding(
              // Widens the tap target without shifting the label's baseline.
              padding: const EdgeInsets.symmetric(
                horizontal: Gap.xs,
                vertical: Gap.xxs,
              ),
              child: Text(
                actionLabel!,
                style: context.text.labelLarge!.copyWith(
                  color: tokens.textSecondary,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
