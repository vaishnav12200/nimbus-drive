import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';
import 'pressable.dart';

enum TransferState { queued, running, paused, done, failed }

/// A file moving to or from Telegram.
///
/// This app's uploads are slow and worth watching: a large file is chunked
/// into 19 MB pieces and forwarded over MTProto, so a 1 GB upload is a
/// long-running, resumable, failable thing rather than a brief spinner. This
/// row is the only place that story is told, so it carries state, progress,
/// a rate and a cancel affordance rather than just a bar.
class NimbusTransferRow extends StatelessWidget {
  const NimbusTransferRow({
    super.key,
    required this.name,
    required this.state,
    this.progress,
    this.detail,
    this.icon = Icons.insert_drive_file_rounded,
    this.accent,
    this.onCancel,
    this.onRetry,
    this.onTap,
  });

  final String name;
  final TransferState state;

  /// 0..1, or null for indeterminate — which is honest during the reserve and
  /// finalise steps, where there is genuinely nothing to count.
  final double? progress;

  /// Right-hand line: "12.4 MB / 512 MB · 2.1 MB/s", or an error message.
  final String? detail;

  final IconData icon;
  final Color? accent;
  final VoidCallback? onCancel;
  final VoidCallback? onRetry;
  final VoidCallback? onTap;

  Color _stateColor(NimbusTokens tokens) => switch (state) {
    TransferState.done => AppColors.success,
    TransferState.failed => AppColors.danger,
    TransferState.paused => tokens.textSecondary,
    _ => accent ?? AppColors.primary,
  };

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final tint = _stateColor(tokens);

    return Pressable(
      onTap: onTap,
      scale: 0.985,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Gap.sm,
          vertical: Gap.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: tint.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
              child: Icon(
                switch (state) {
                  TransferState.done => Icons.check_rounded,
                  TransferState.failed => Icons.priority_high_rounded,
                  TransferState.paused => Icons.pause_rounded,
                  _ => icon,
                },
                size: 21,
                color: tint,
              ),
            ),
            const SizedBox(width: Gap.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.text.bodyLarge!.copyWith(
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (progress != null && state == TransferState.running)
                        Text(
                          '${(progress! * 100).round()}%',
                          style: context.text.bodySmall!.copyWith(color: tint),
                        ),
                    ],
                  ),
                  const SizedBox(height: Gap.xs),

                  // The bar stays visible when finished or failed, filled or
                  // stopped where it died. A row that loses its bar on
                  // completion makes the list twitch as items settle.
                  ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.pill),
                    child: LinearProgressIndicator(
                      value: state == TransferState.done ? 1 : progress,
                      minHeight: 4,
                      backgroundColor: tokens.raisedHigh,
                      valueColor: AlwaysStoppedAnimation(tint),
                    ),
                  ),

                  if (detail != null) ...[
                    const SizedBox(height: Gap.xs - 2),
                    Text(
                      detail!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodySmall!.copyWith(
                        color: state == TransferState.failed
                            ? AppColors.danger
                            : tokens.textTertiary,
                      ),
                    ),
                  ],
                ],
              ),
            ),

            if (state == TransferState.failed && onRetry != null) ...[
              const SizedBox(width: Gap.xs),
              _Action(
                icon: Icons.refresh_rounded,
                onTap: onRetry!,
                label: 'Retry',
              ),
            ] else if (onCancel != null &&
                state != TransferState.done &&
                state != TransferState.failed) ...[
              const SizedBox(width: Gap.xs),
              _Action(
                icon: Icons.close_rounded,
                onTap: onCancel!,
                label: 'Cancel',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.icon, required this.onTap, required this.label});

  final IconData icon;
  final VoidCallback onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: true,
      child: Pressable(
        onTap: onTap,
        scale: 0.9,
        child: SizedBox.square(
          dimension: 32,
          child: Icon(icon, size: 18, color: context.tokens.textSecondary),
        ),
      ),
    );
  }
}
