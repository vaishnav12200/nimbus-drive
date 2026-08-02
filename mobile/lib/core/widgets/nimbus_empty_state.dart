import 'package:flutter/material.dart';

import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';
import 'nimbus_button.dart';

/// Empty folder, no search results, no share links, empty trash.
///
/// Every list in this app can be empty, and each empty case means something
/// different: an empty folder invites an upload, an empty search result means
/// try different words, an empty trash is simply good news. So [action] is
/// optional — offering "Upload" on a trash screen is worse than offering
/// nothing.
class NimbusEmptyState extends StatelessWidget {
  const NimbusEmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
    this.accent,
  });

  final IconData icon;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  /// Tints the icon halo. Defaults to a neutral surface — an empty state is
  /// not an error and should not draw the eye like one.
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final tint = accent ?? tokens.textSecondary;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.xxl,
          vertical: Gap.xxl,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 32, color: tint),
            ),
            const SizedBox(height: Gap.lg),
            Text(
              title,
              textAlign: TextAlign.center,
              style: context.text.titleLarge,
            ),
            if (message != null) ...[
              const SizedBox(height: Gap.xs),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: context.text.bodyMedium!.copyWith(
                  color: tokens.textSecondary,
                ),
              ),
            ],
            if (actionLabel != null) ...[
              const SizedBox(height: Gap.lg),
              NimbusButton(label: actionLabel!, onPressed: onAction),
            ],
          ],
        ),
      ),
    );
  }
}
