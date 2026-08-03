import 'package:flutter/material.dart';

import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';
import 'pressable.dart';

/// The default container: a rounded, filled surface.
///
/// Almost every grouped region in the app is one of these. Passing [color]
/// turns it into an accent card (the lime storage hero, the purple insight
/// card) without a separate widget, since the only thing that changes is the
/// fill and the contrast of whatever is placed inside it.
class NimbusCard extends StatelessWidget {
  const NimbusCard({
    super.key,
    required this.child,
    this.color,
    this.padding = const EdgeInsets.all(Gap.md),
    this.radius = Radii.lg,
    this.onTap,
    this.onLongPress,
    this.bordered = false,
    this.shadow = false,
    this.width,
    this.height,
  });

  final Widget child;

  /// Fill. Defaults to the neutral raised surface.
  final Color? color;

  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Hairline outline. For cards that sit directly on `canvas` and need an
  /// edge — a bordered card and a filled card should not be combined.
  final bool bordered;

  final bool shadow;
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final borderRadius = BorderRadius.circular(radius);

    final container = AnimatedContainer(
      duration: Motion.fast,
      curve: Motion.decelerate,
      width: width,
      height: height,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? tokens.raised,
        borderRadius: borderRadius,
        border: bordered ? Border.all(color: tokens.outline) : null,
        boxShadow: shadow ? tokens.cardShadow : null,
      ),
      child: child,
    );

    if (onTap == null && onLongPress == null) return container;

    return Pressable(
      onTap: onTap,
      onLongPress: onLongPress,
      // Full-width cards travel a long way at the default scale; ease off.
      scale: 0.985,
      child: container,
    );
  }
}
