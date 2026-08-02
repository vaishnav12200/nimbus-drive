import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';
import 'pressable.dart';

@immutable
class NimbusNavItem {
  const NimbusNavItem({required this.icon, required this.label});

  final IconData icon;

  /// Not painted — the bar is icon-only, matching the reference. Used for the
  /// accessibility label, which is the only reason a screen reader can tell
  /// these five circles apart.
  final String label;
}

/// Floating pill navigation bar.
///
/// Detached from the screen edge and centred, with the selected item filled
/// lime. The selection indicator is a real sliding element rather than a
/// per-item colour swap, so moving between tabs reads as one object travelling
/// instead of two independent fades.
class NimbusNavBar extends StatelessWidget {
  const NimbusNavBar({
    super.key,
    required this.items,
    required this.currentIndex,
    required this.onChanged,
  });

  final List<NimbusNavItem> items;
  final int currentIndex;
  final ValueChanged<int> onChanged;

  static const double _slot = 52;
  static const double _padding = 6;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return Padding(
      // Sits above the home indicator rather than under it.
      padding: EdgeInsets.only(
        left: Gap.page,
        right: Gap.page,
        bottom: MediaQuery.viewPaddingOf(context).bottom + Gap.sm,
      ),
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(_padding),
          decoration: BoxDecoration(
            color: tokens.floating,
            borderRadius: BorderRadius.circular(Radii.pill),
            boxShadow: tokens.floatingShadow,
          ),
          child: Stack(
            children: [
              AnimatedPositioned(
                duration: Motion.slow,
                curve: Motion.emphasized,
                left: currentIndex * _slot,
                child: Container(
                  width: _slot,
                  height: _slot,
                  decoration: const BoxDecoration(
                    color: AppColors.primary,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < items.length; i++)
                    Pressable(
                      onTap: i == currentIndex ? null : () => onChanged(i),
                      scale: 0.9,
                      child: SizedBox.square(
                        dimension: _slot,
                        child: Semantics(
                          label: items[i].label,
                          selected: i == currentIndex,
                          button: true,
                          child: TweenAnimationBuilder<Color?>(
                            duration: Motion.normal,
                            curve: Motion.decelerate,
                            tween: ColorTween(
                              end: i == currentIndex
                                  ? AppColors.onPrimary
                                  : tokens.textSecondary,
                            ),
                            builder: (context, color, _) =>
                                Icon(items[i].icon, size: 22, color: color),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
