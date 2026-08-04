import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/nimbus_avatar.dart';
import '../../core/widgets/nimbus_breakdown.dart';
import '../../core/widgets/nimbus_button.dart';
import '../../core/widgets/nimbus_card.dart';
import '../../core/widgets/nimbus_chip.dart';
import '../../core/widgets/nimbus_empty_state.dart';
import '../../core/widgets/nimbus_list_row.dart';
import '../../core/widgets/nimbus_skeleton.dart';
import '../../core/widgets/pressable.dart';
import '../files/models/drive_item.dart';
import 'home_controller.dart';

/// The drive at a glance: how full it is, what fills it, what changed lately.
///
/// Every control here is a shortcut into another tab — Home owns no actions of
/// its own. That is deliberate: a summary screen that can also mutate things
/// ends up disagreeing with the screen that owns them.
class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.controller,
    required this.userName,
    required this.onOpenFiles,
    required this.onOpenUpload,
    required this.onOpenSettings,
  });

  final HomeController controller;

  /// The signed-in account's name, for the avatar. Passed in rather than read
  /// from a global so this screen stays testable without an auth session.
  final String userName;

  /// Switches to Files, optionally pre-filtered to one category.
  final void Function({FileType? type}) onOpenFiles;

  final VoidCallback onOpenUpload;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) => SafeArea(
        bottom: false,
        child: RefreshIndicator(
          onRefresh: controller.load,
          backgroundColor: context.tokens.raised,
          color: AppColors.primary,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xs, Gap.page, 104),
            children: [
              _Header(
                userName: userName,
                onSearch: () => onOpenFiles(),
                onProfile: onOpenSettings,
              ),
              const SizedBox(height: Gap.lg),

              if (controller.loading)
                const _LoadingBody()
              else if (controller.summary == null)
                NimbusEmptyState(
                  icon: Icons.cloud_off_rounded,
                  title: 'Could not load your drive',
                  message: controller.error,
                  actionLabel: 'Try again',
                  accent: AppColors.danger,
                  onAction: controller.load,
                )
              else ...[
                _StorageCard(
                  controller: controller,
                  onOpenSettings: onOpenSettings,
                ),
                const SizedBox(height: Gap.md),
                _QuickActions(
                  onUpload: onOpenUpload,
                  onBrowse: () => onOpenFiles(),
                ),
                const SizedBox(height: Gap.xl),

                _Breakdown(controller: controller, onOpenFiles: onOpenFiles),
                const SizedBox(height: Gap.xl),

                _Recent(controller: controller, onOpenFiles: onOpenFiles),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.userName,
    required this.onSearch,
    required this.onProfile,
  });

  final String userName;
  final VoidCallback onSearch;
  final VoidCallback onProfile;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.cloud_rounded, color: AppColors.primary, size: 26),
        const SizedBox(width: Gap.xs),
        Text('Nimbus', style: context.text.titleLarge),
        const Spacer(),
        NimbusIconButton(
          icon: Icons.search_rounded,
          tooltip: 'Search files',
          onPressed: onSearch,
        ),
        const SizedBox(width: Gap.xs),
        // Profile lives here rather than in the nav bar, so the bar is five
        // places to go rather than four places and an account button.
        Semantics(
          label: 'Account and settings',
          button: true,
          child: Pressable(
            onTap: onProfile,
            scale: 0.92,
            child: NimbusAvatar(name: userName),
          ),
        ),
      ],
    );
  }
}

/// The lime hero. One per screen — this is the element the palette is built
/// around, and a second one anywhere would flatten it.
class _StorageCard extends StatelessWidget {
  const _StorageCard({required this.controller, required this.onOpenSettings});

  final HomeController controller;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    // Content on lime is black at varying alpha rather than a second hue.
    const ink = AppColors.onPrimary;
    final inkMuted = ink.withValues(alpha: 0.6);
    final summary = controller.summary!;

    // "48.2 GB" split so the unit can take the smaller, muted style.
    final used = formatBytes(summary.storageUsed).split(' ');

    return NimbusCard(
      color: AppColors.primary,
      radius: Radii.xl,
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // A label, not a control. There is one workspace, and a chevron
              // that opens nothing is worse than no chevron.
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Gap.sm,
                  vertical: Gap.xs,
                ),
                decoration: BoxDecoration(
                  color: ink,
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
                child: Text(
                  'Personal',
                  style: context.text.labelLarge!.copyWith(
                    color: AppColors.primary,
                  ),
                ),
              ),
              const Spacer(),
              NimbusIconButton(
                icon: Icons.refresh_rounded,
                size: 36,
                background: ink,
                foreground: AppColors.primary,
                tooltip: 'Refresh',
                onPressed: controller.load,
              ),
              const SizedBox(width: Gap.xs),
              NimbusIconButton(
                icon: Icons.tune_rounded,
                size: 36,
                background: ink,
                foreground: AppColors.primary,
                tooltip: 'Storage settings',
                onPressed: onOpenSettings,
              ),
            ],
          ),
          const SizedBox(height: Gap.lg),

          Text(
            'STORAGE USED',
            style: context.text.labelSmall!.copyWith(color: inkMuted),
          ),
          const SizedBox(height: Gap.xxs),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                used.first,
                style: context.text.displayLarge!.copyWith(color: ink),
              ),
              const SizedBox(width: Gap.xxs),
              Text(
                used.last,
                style: context.text.titleLarge!.copyWith(color: inkMuted),
              ),
              const Spacer(),
              Text(
                'of ${formatBytes(summary.storageQuota)}',
                style: context.text.bodyMedium!.copyWith(color: inkMuted),
              ),
            ],
          ),
          const SizedBox(height: Gap.md),

          // Track and fill are both black-on-lime; the pastel accents would
          // fight the card at this size.
          ClipRRect(
            borderRadius: BorderRadius.circular(Radii.pill),
            child: LinearProgressIndicator(
              value: summary.usedFraction,
              minHeight: 8,
              backgroundColor: ink.withValues(alpha: 0.18),
              valueColor: const AlwaysStoppedAnimation(ink),
            ),
          ),
        ],
      ),
    );
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({required this.onUpload, required this.onBrowse});

  final VoidCallback onUpload;
  final VoidCallback onBrowse;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: NimbusButton(
            label: 'Upload',
            icon: Icons.arrow_upward_rounded,
            expand: true,
            onPressed: onUpload,
          ),
        ),
        const SizedBox(width: Gap.xs),
        NimbusIconButton(
          icon: Icons.folder_open_rounded,
          size: 52,
          tooltip: 'Browse files',
          onPressed: onBrowse,
        ),
      ],
    );
  }
}

class _Breakdown extends StatelessWidget {
  const _Breakdown({required this.controller, required this.onOpenFiles});

  final HomeController controller;
  final void Function({FileType? type}) onOpenFiles;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final byType = controller.summary!.bytesByType;

    if (byType.isEmpty) return const SizedBox.shrink();

    final entries = byType.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NimbusSectionHeader(
          title: 'Storage by type',
          actionLabel: 'Browse',
          onAction: () => onOpenFiles(),
        ),
        const SizedBox(height: Gap.sm),
        NimbusCard(
          padding: const EdgeInsets.all(Gap.md),
          child: NimbusBreakdown(
            segments: [
              for (final e in entries)
                BreakdownSegment(
                  label: e.key.label,
                  value: e.value.toDouble(),
                  color: tokens.accentForType(e.key.wire),
                  trailing: formatBytes(e.value),
                ),
            ],
            // Tapping a category is a question about files, so it is answered
            // on the Files tab rather than by expanding something here.
            onSegmentTap: (segment) => onOpenFiles(
              type: entries.firstWhere((e) => e.key.label == segment.label).key,
            ),
          ),
        ),
      ],
    );
  }
}

class _Recent extends StatelessWidget {
  const _Recent({required this.controller, required this.onOpenFiles});

  final HomeController controller;
  final void Function({FileType? type}) onOpenFiles;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final recent = controller.recent;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        NimbusSectionHeader(
          title: 'Recent',
          actionLabel: 'See all',
          onAction: () => onOpenFiles(type: controller.recentFilter),
        ),
        const SizedBox(height: Gap.sm),

        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          child: Row(
            children: [
              NimbusChip(
                label: 'All',
                selected: controller.recentFilter == null,
                onTap: () => controller.setRecentFilter(null),
              ),
              for (final type in controller.availableTypes) ...[
                const SizedBox(width: Gap.xs),
                NimbusChip(
                  label: type.label,
                  selected: controller.recentFilter == type,
                  accent: tokens.accentForType(type.wire),
                  onTap: () => controller.setRecentFilter(type),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: Gap.xs),

        if (recent.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: Gap.md),
            child: NimbusEmptyState(
              icon: Icons.history_rounded,
              title: 'Nothing here yet',
              message: 'No recent files in this category.',
              actionLabel: 'Show all',
              onAction: () => controller.setRecentFilter(null),
            ),
          )
        else
          for (final file in recent)
            NimbusListRow(
              title: file.name,
              subtitle:
                  '${formatBytes(file.size)} · ${formatWhen(file.updatedAt)}',
              icon: file.type.icon,
              iconColor: tokens.accentForType(file.type.wire),
              trailing: file.isEncrypted
                  ? Icon(
                      Icons.lock_rounded,
                      size: 16,
                      color: tokens.textTertiary,
                    )
                  : null,
              // Home summarises; the Files tab is where a file is acted on.
              onTap: () => onOpenFiles(type: file.type),
            ),
      ],
    );
  }
}

class _LoadingBody extends StatelessWidget {
  const _LoadingBody();

  @override
  Widget build(BuildContext context) {
    return const NimbusSkeletonGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          NimbusSkeleton(height: 168, radius: Radii.xl),
          SizedBox(height: Gap.md),
          NimbusSkeleton(height: 52, radius: Radii.pill),
          SizedBox(height: Gap.xl),
          NimbusSkeleton(width: 150, height: 18),
          SizedBox(height: Gap.sm),
          NimbusSkeleton(height: 260, radius: Radii.lg),
        ],
      ),
    );
  }
}
