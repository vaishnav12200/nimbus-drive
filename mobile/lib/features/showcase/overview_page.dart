import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/nimbus_avatar.dart';
import '../../core/widgets/nimbus_breakdown.dart';
import '../../core/widgets/nimbus_button.dart';
import '../../core/widgets/nimbus_card.dart';
import '../../core/widgets/nimbus_chip.dart';
import '../../core/widgets/nimbus_list_row.dart';
import '../../core/widgets/pressable.dart';

/// A drive home screen built only from the shared widgets.
///
/// Everything here is placeholder data. The point is to show the system under
/// realistic density — a palette laid out as swatches always looks fine; the
/// question is whether it survives six accents, a hero card and a file list on
/// one screen.
class OverviewPage extends StatefulWidget {
  const OverviewPage({super.key});

  @override
  State<OverviewPage> createState() => _OverviewPageState();
}

class _OverviewPageState extends State<OverviewPage> {
  int _filter = 0;

  static const _filters = ['All', 'Images', 'Video', 'Docs'];

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    final breakdown = [
      BreakdownSegment(
        label: 'Video',
        value: 21.4,
        color: tokens.accentForType('video'),
        trailing: '21.4 GB',
      ),
      BreakdownSegment(
        label: 'Images',
        value: 12.8,
        color: tokens.accentForType('image'),
        trailing: '12.8 GB',
      ),
      BreakdownSegment(
        label: 'Documents',
        value: 8.1,
        color: tokens.accentForType('document'),
        trailing: '8.1 GB',
      ),
      BreakdownSegment(
        label: 'Audio',
        value: 4.2,
        color: tokens.accentForType('audio'),
        trailing: '4.2 GB',
      ),
      BreakdownSegment(
        label: 'Archives',
        value: 1.7,
        color: tokens.accentForType('archive'),
        trailing: '1.7 GB',
      ),
    ];

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          Gap.page,
          Gap.xs,
          Gap.page,
          // Clears the floating nav bar, which overlays the scroll view.
          104,
        ),
        children: [
          const _Header(),
          const SizedBox(height: Gap.lg),
          const _StorageCard(),
          const SizedBox(height: Gap.md),
          const _QuickActions(),
          const SizedBox(height: Gap.xl),

          NimbusSectionHeader(title: 'Storage by type', onAction: () {}),
          const SizedBox(height: Gap.sm),
          NimbusCard(
            padding: const EdgeInsets.all(Gap.md),
            child: NimbusBreakdown(segments: breakdown, onSegmentTap: (_) {}),
          ),
          const SizedBox(height: Gap.xl),

          NimbusSectionHeader(
            title: 'Recent',
            actionLabel: 'See all',
            onAction: () {},
          ),
          const SizedBox(height: Gap.sm),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            child: Row(
              children: [
                for (var i = 0; i < _filters.length; i++) ...[
                  if (i > 0) const SizedBox(width: Gap.xs),
                  NimbusChip(
                    label: _filters[i],
                    selected: i == _filter,
                    onTap: () => setState(() => _filter = i),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: Gap.xs),

          for (final file in _sampleFiles)
            NimbusListRow(
              title: file.name,
              subtitle: '${file.size} · ${file.when}',
              icon: file.icon,
              iconColor: tokens.accentForType(file.type),
              trailing: file.encrypted
                  ? Icon(
                      Icons.lock_rounded,
                      size: 16,
                      color: tokens.textTertiary,
                    )
                  : null,
              onTap: () {},
              onLongPress: () {},
            ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(Icons.cloud_rounded, color: AppColors.primary, size: 26),
        const SizedBox(width: Gap.xs),
        Text('Nimbus', style: context.text.titleLarge),
        const Spacer(),
        NimbusIconButton(icon: Icons.search_rounded, onPressed: () {}),
        const SizedBox(width: Gap.xs),
        // Profile lives here rather than in the nav bar, so the bar is five
        // places to go rather than four places and an account button.
        Pressable(
          onTap: () {},
          scale: 0.92,
          child: const NimbusAvatar(name: 'Vaishnav K M'),
        ),
      ],
    );
  }
}

/// The lime hero. One per screen — this is the element the palette is built
/// around, and a second one anywhere would flatten it.
class _StorageCard extends StatelessWidget {
  const _StorageCard();

  @override
  Widget build(BuildContext context) {
    // Content on lime is black at varying alpha rather than a second hue.
    const ink = AppColors.onPrimary;
    final inkMuted = ink.withValues(alpha: 0.6);

    return NimbusCard(
      color: AppColors.primary,
      radius: Radii.xl,
      padding: const EdgeInsets.all(Gap.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: Gap.sm,
                  vertical: Gap.xs,
                ),
                decoration: BoxDecoration(
                  color: ink,
                  borderRadius: BorderRadius.circular(Radii.pill),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Personal',
                      style: context.text.labelLarge!.copyWith(
                        color: AppColors.primary,
                      ),
                    ),
                    const SizedBox(width: Gap.xxs),
                    const Icon(
                      Icons.expand_more_rounded,
                      size: 16,
                      color: AppColors.primary,
                    ),
                  ],
                ),
              ),
              const Spacer(),
              NimbusIconButton(
                icon: Icons.bolt_rounded,
                size: 36,
                background: ink,
                foreground: AppColors.primary,
                onPressed: () {},
              ),
              const SizedBox(width: Gap.xs),
              NimbusIconButton(
                icon: Icons.tune_rounded,
                size: 36,
                background: ink,
                foreground: AppColors.primary,
                onPressed: () {},
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
                '48.2',
                style: context.text.displayLarge!.copyWith(color: ink),
              ),
              const SizedBox(width: Gap.xxs),
              Text(
                'GB',
                style: context.text.titleLarge!.copyWith(color: inkMuted),
              ),
              const Spacer(),
              Text(
                'of 100 GB',
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
              value: 0.482,
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
  const _QuickActions();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: NimbusButton(
            label: 'Upload',
            icon: Icons.arrow_upward_rounded,
            expand: true,
            onPressed: () {},
          ),
        ),
        const SizedBox(width: Gap.xs),
        NimbusIconButton(
          icon: Icons.create_new_folder_outlined,
          size: 52,
          onPressed: () {},
        ),
        const SizedBox(width: Gap.xs),
        NimbusIconButton(
          icon: Icons.qr_code_rounded,
          size: 52,
          onPressed: () {},
        ),
      ],
    );
  }
}

@immutable
class _SampleFile {
  const _SampleFile(
    this.name,
    this.type,
    this.icon,
    this.size,
    this.when, {
    this.encrypted = false,
  });

  final String name;
  final String type;
  final IconData icon;
  final String size;
  final String when;
  final bool encrypted;
}

const _sampleFiles = [
  _SampleFile(
    'Q3 architecture review.pdf',
    'document',
    Icons.description_rounded,
    '2.4 MB',
    '10:24',
    encrypted: true,
  ),
  _SampleFile(
    'launch-teaser-final.mp4',
    'video',
    Icons.movie_rounded,
    '412 MB',
    'Yesterday',
  ),
  _SampleFile(
    'IMG_20260731_sunset.heic',
    'image',
    Icons.image_rounded,
    '4.8 MB',
    'Yesterday',
  ),
  _SampleFile(
    'interview-notes.m4a',
    'audio',
    Icons.graphic_eq_rounded,
    '18.2 MB',
    'Jul 30',
  ),
  _SampleFile(
    'nimbus-backup-2026-07.zip',
    'archive',
    Icons.folder_zip_rounded,
    '1.2 GB',
    'Jul 28',
    encrypted: true,
  ),
];
