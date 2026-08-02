import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';
import 'pressable.dart';

enum NimbusButtonVariant {
  /// Lime on black text. The one action a screen most wants you to take —
  /// at most one per viewport, or the emphasis stops meaning anything.
  primary,

  /// Neutral raised surface. Everything else.
  secondary,

  /// Outline only, for actions that sit next to a primary and must not
  /// compete with it.
  ghost,

  /// Destructive and irreversible: empty trash, delete permanently.
  danger,
}

enum NimbusButtonSize { small, regular, large }

/// Pill-shaped button.
///
/// Fully rounded at every size, matching the reference — the radius is not a
/// per-size decision, it is the shape.
class NimbusButton extends StatelessWidget {
  const NimbusButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = NimbusButtonVariant.primary,
    this.size = NimbusButtonSize.regular,
    this.icon,
    this.trailingIcon,
    this.expand = false,
    this.loading = false,
  });

  final String label;

  /// Null disables the button. So does [loading], which additionally swaps the
  /// label for a spinner *without* changing the button's width — a button that
  /// resizes when tapped makes the whole row jump.
  final VoidCallback? onPressed;

  final NimbusButtonVariant variant;
  final NimbusButtonSize size;
  final IconData? icon;
  final IconData? trailingIcon;
  final bool expand;
  final bool loading;

  bool get _enabled => onPressed != null && !loading;

  double get _height => switch (size) {
    NimbusButtonSize.small => 38,
    NimbusButtonSize.regular => 52,
    NimbusButtonSize.large => 60,
  };

  double get _padding => switch (size) {
    NimbusButtonSize.small => Gap.md,
    NimbusButtonSize.regular => Gap.xl,
    NimbusButtonSize.large => Gap.xxl,
  };

  double get _iconSize => size == NimbusButtonSize.small ? 16 : 19;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    final (
      Color background,
      Color foreground,
      Color? border,
    ) = switch (variant) {
      NimbusButtonVariant.primary => (
        AppColors.primary,
        AppColors.onPrimary,
        null,
      ),
      NimbusButtonVariant.secondary => (
        tokens.raised,
        tokens.textPrimary,
        null,
      ),
      NimbusButtonVariant.ghost => (
        Colors.transparent,
        tokens.textPrimary,
        tokens.outlineStrong,
      ),
      NimbusButtonVariant.danger => (AppColors.danger, Colors.white, null),
    };

    final textStyle =
        (size == NimbusButtonSize.large
                ? context.text.titleMedium!
                : context.text.labelLarge!)
            .copyWith(color: foreground);

    // Disabling dims the whole button rather than recolouring it, so a
    // disabled primary is still recognisably the primary.
    final content = AnimatedOpacity(
      duration: Motion.fast,
      opacity: _enabled ? 1 : 0.4,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.decelerate,
        height: _height,
        padding: EdgeInsets.symmetric(horizontal: _padding),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(Radii.pill),
          border: border == null ? null : Border.all(color: border, width: 1.5),
        ),
        child: Row(
          mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading)
              SizedBox.square(
                dimension: _iconSize,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: foreground,
                ),
              )
            else ...[
              if (icon != null) ...[
                Icon(icon, size: _iconSize, color: foreground),
                const SizedBox(width: Gap.xs),
              ],
              Flexible(
                child: Text(
                  label,
                  style: textStyle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (trailingIcon != null) ...[
                const SizedBox(width: Gap.xs),
                Icon(trailingIcon, size: _iconSize, color: foreground),
              ],
            ],
          ],
        ),
      ),
    );

    return Pressable(
      onTap: _enabled ? onPressed : null,
      scale: expand ? 0.98 : Motion.pressScale,
      child: content,
    );
  }
}

/// Circular icon button — the white pills on the reference's hero card, and
/// the neutral ones in headers and nav bars.
class NimbusIconButton extends StatelessWidget {
  const NimbusIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.size = 44,
    this.background,
    this.foreground,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final Color? background;
  final Color? foreground;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    Widget button = Pressable(
      onTap: onPressed,
      scale: 0.92,
      child: AnimatedContainer(
        duration: Motion.fast,
        curve: Motion.decelerate,
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: background ?? tokens.raised,
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: size * 0.44,
          color: foreground ?? tokens.textPrimary,
        ),
      ),
    );

    if (tooltip != null) button = Tooltip(message: tooltip!, child: button);
    return button;
  }
}
