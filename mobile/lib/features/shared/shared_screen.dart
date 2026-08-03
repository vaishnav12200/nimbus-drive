import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/nimbus_card.dart';
import '../../core/widgets/nimbus_chip.dart';
import '../../core/widgets/nimbus_empty_state.dart';
import '../../core/widgets/nimbus_feedback.dart';
import '../../core/widgets/nimbus_skeleton.dart';
import '../../core/widgets/pressable.dart';
import 'models/share_link.dart';
import 'shares_controller.dart';

/// Public links you have handed out.
///
/// The point of this screen is revocation. A share link is the only way data
/// leaves this account, so every row leads with what it exposes — downloads
/// used, time left, whether a password guards it — and revoke is one tap away.
class SharedScreen extends StatelessWidget {
  const SharedScreen({super.key, required this.controller});

  final SharesController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => SafeArea(
        bottom: false,
        child: Column(
          children: [
            _Header(controller: controller),
            Expanded(child: _Body(controller: controller)),
          ],
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final SharesController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xs, Gap.page, Gap.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Shared', style: context.text.headlineMedium),
          const SizedBox(height: Gap.xxs),
          Text(
            'Anyone with these links can download the file.',
            style: context.text.bodyMedium!.copyWith(
              color: context.tokens.textSecondary,
            ),
          ),
          const SizedBox(height: Gap.md),

          Row(
            children: [
              for (final filter in ShareFilter.values) ...[
                NimbusChip(
                  label: filter.label,
                  count: controller.countFor(filter),
                  selected: controller.filter == filter,
                  accent: filter == ShareFilter.expired
                      ? AppColors.danger
                      : AppColors.primary,
                  onTap: () => controller.setFilter(filter),
                ),
                const SizedBox(width: Gap.xs),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.controller});

  final SharesController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.loading) {
      return const NimbusSkeletonGroup(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: Gap.page),
          child: Column(
            children: [
              NimbusRowSkeleton(titleWidth: 180),
              NimbusRowSkeleton(titleWidth: 140),
              NimbusRowSkeleton(titleWidth: 210),
            ],
          ),
        ),
      );
    }

    if (controller.error != null) {
      return NimbusEmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Could not load your links',
        message: controller.error,
        actionLabel: 'Try again',
        accent: AppColors.danger,
        onAction: controller.load,
      );
    }

    if (controller.links.isEmpty) {
      // "No links at all" and "none in this filter" are different situations.
      return controller.hasAny
          ? NimbusEmptyState(
              icon: Icons.filter_alt_off_rounded,
              title: 'Nothing in this view',
              message: 'Try the other filter to see the rest of your links.',
              actionLabel: 'Show all',
              onAction: () => controller.setFilter(controller.filter!),
            )
          : const NimbusEmptyState(
              icon: Icons.link_off_rounded,
              title: 'No share links yet',
              message:
                  'Long-press a file and choose "Copy share link" to create '
                  'one. Encrypted files cannot be shared.',
            );
    }

    return RefreshIndicator(
      onRefresh: controller.load,
      backgroundColor: context.tokens.raised,
      color: AppColors.primary,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, 104),
        itemCount: controller.links.length,
        separatorBuilder: (_, _) => const SizedBox(height: Gap.xs),
        itemBuilder: (context, i) =>
            _LinkCard(link: controller.links[i], controller: controller),
      ),
    );
  }
}

class _LinkCard extends StatelessWidget {
  const _LinkCard({required this.link, required this.controller});

  final ShareLink link;
  final SharesController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final dead = link.isDead;
    final accent = tokens.accentForType(link.fileType.wire);

    return NimbusCard(
      onTap: () => _copy(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  // A dead link's icon goes neutral, so a glance down the list
                  // separates live from spent without reading a word.
                  color: (dead ? tokens.textTertiary : accent).withValues(
                    alpha: 0.16,
                  ),
                  borderRadius: BorderRadius.circular(Radii.sm),
                ),
                child: Icon(
                  link.fileType.icon,
                  size: 20,
                  color: dead ? tokens.textTertiary : accent,
                ),
              ),
              const SizedBox(width: Gap.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      link.fileName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.text.bodyLarge!.copyWith(
                        fontWeight: FontWeight.w500,
                        color: dead ? tokens.textSecondary : tokens.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${formatBytes(link.fileSize)} · shared '
                      '${formatWhen(link.createdAt)}',
                      style: context.text.bodySmall!.copyWith(
                        color: tokens.textTertiary,
                      ),
                    ),
                  ],
                ),
              ),
              Semantics(
                label: 'Revoke link',
                button: true,
                child: Pressable(
                  onTap: () => _confirmRevoke(context),
                  scale: 0.9,
                  child: const SizedBox.square(
                    dimension: 36,
                    child: Icon(
                      Icons.link_off_rounded,
                      size: 19,
                      color: AppColors.danger,
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Gap.sm),

          Wrap(
            spacing: Gap.xs,
            runSpacing: Gap.xxs,
            children: [
              if (dead)
                _Tag(
                  icon: Icons.block_rounded,
                  label: link.isExhausted
                      ? 'Download limit reached'
                      : 'Expired',
                  color: AppColors.danger,
                )
              else if (link.expiresAt != null)
                _Tag(
                  icon: Icons.schedule_rounded,
                  label: '${link.daysRemaining}d left',
                  color: tokens.textSecondary,
                )
              else
                _Tag(
                  icon: Icons.all_inclusive_rounded,
                  label: 'No expiry',
                  color: tokens.textSecondary,
                ),

              _Tag(
                icon: Icons.download_rounded,
                label: link.maxDownloads == null
                    ? '${link.downloadCount} downloads'
                    : '${link.downloadCount} of ${link.maxDownloads}',
                color: tokens.textSecondary,
              ),

              if (link.hasPassword)
                const _Tag(
                  icon: Icons.lock_rounded,
                  label: 'Password',
                  color: AppColors.warning,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _copy(BuildContext context) async {
    // Copying a dead link would hand someone a URL that answers 410.
    if (link.isDead) {
      NimbusFeedback.error(context, 'This link no longer works');
      return;
    }
    await Clipboard.setData(ClipboardData(text: link.url));
    if (context.mounted) NimbusFeedback.success(context, 'Link copied');
  }

  Future<void> _confirmRevoke(BuildContext context) async {
    final confirmed = await NimbusFeedback.confirm(
      context,
      title: 'Revoke this link?',
      message:
          'Anyone holding it stops being able to download "${link.fileName}". '
          'The file itself is not affected.',
      confirmLabel: 'Revoke',
    );
    if (!confirmed || !context.mounted) return;

    await controller.revoke(link);
    if (context.mounted) NimbusFeedback.toast(context, 'Link revoked');
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.icon, required this.label, required this.color});

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: color),
        const SizedBox(width: Gap.xxs),
        Text(label, style: context.text.bodySmall!.copyWith(color: color)),
      ],
    );
  }
}
