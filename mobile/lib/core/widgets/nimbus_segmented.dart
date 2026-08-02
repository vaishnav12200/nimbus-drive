import 'package:flutter/material.dart';

import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';
import 'pressable.dart';

/// Inline text tabs — "Files / Shared", "Expenses / Savings Goals" in the
/// reference.
///
/// No pill, no underline, no container. The only signal is weight and colour,
/// which is why it can sit directly against content without adding a visual
/// layer. For switching between more than three views, use a real tab bar.
class NimbusSegmented extends StatelessWidget {
  const NimbusSegmented({
    super.key,
    required this.segments,
    required this.selectedIndex,
    required this.onChanged,
    this.trailing,
  });

  final List<String> segments;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  /// Optional action pinned to the far right — a calendar or sort button.
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return Row(
      children: [
        for (var i = 0; i < segments.length; i++) ...[
          if (i > 0) const SizedBox(width: Gap.lg),
          Pressable(
            onTap: i == selectedIndex ? null : () => onChanged(i),
            scale: 0.95,
            child: AnimatedDefaultTextStyle(
              duration: Motion.normal,
              curve: Motion.decelerate,
              style: context.text.titleLarge!.copyWith(
                color: i == selectedIndex
                    ? tokens.textPrimary
                    : tokens.textTertiary,
              ),
              child: Text(segments[i]),
            ),
          ),
        ],
        if (trailing != null) ...[const Spacer(), trailing!],
      ],
    );
  }
}
