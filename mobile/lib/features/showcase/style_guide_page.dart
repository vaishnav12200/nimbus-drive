import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/nimbus_button.dart';
import '../../core/widgets/nimbus_card.dart';
import '../../core/widgets/nimbus_chip.dart';
import '../../core/widgets/nimbus_list_row.dart';
import '../../core/widgets/nimbus_segmented.dart';

/// Every token and widget in isolation, so a change to the system can be
/// reviewed in one scroll instead of hunted for across feature screens.
class StyleGuidePage extends StatefulWidget {
  const StyleGuidePage({super.key});

  @override
  State<StyleGuidePage> createState() => _StyleGuidePageState();
}

class _StyleGuidePageState extends State<StyleGuidePage> {
  int _segment = 0;
  int _chip = 1;
  bool _loading = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xs, Gap.page, 104),
        children: [
          Text('Style guide', style: context.text.headlineMedium),
          const SizedBox(height: Gap.xxs),
          Text(
            'Sampled from the Ronas IT fintech reference.',
            style: context.text.bodyMedium!.copyWith(
              color: tokens.textSecondary,
            ),
          ),
          const SizedBox(height: Gap.xl),

          _Section(
            title: 'Surfaces',
            child: Row(
              children: [
                _Swatch('canvas', tokens.canvas, bordered: true),
                _Swatch('surface', tokens.surface),
                _Swatch('raised', tokens.raised),
                _Swatch('high', tokens.raisedHigh),
              ],
            ),
          ),

          _Section(
            title: 'Brand',
            child: Row(
              children: [
                _Swatch('primary', AppColors.primary),
                _Swatch('dim', AppColors.primaryDim),
                _Swatch('secondary', AppColors.secondary),
                _Swatch('dim', AppColors.secondaryDim),
              ],
            ),
          ),

          _Section(
            title: 'Category accents',
            child: Row(
              children: [
                for (final type in const [
                  'image',
                  'video',
                  'document',
                  'audio',
                  'archive',
                  'other',
                ])
                  _Swatch(type, tokens.accentForType(type), compact: true),
              ],
            ),
          ),

          _Section(
            title: 'Type scale',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Type('display / 44', context.text.displayLarge!, '48.2 GB'),
                _Type(
                  'headline / 28',
                  context.text.headlineMedium!,
                  'All files',
                ),
                _Type('title / 19', context.text.titleLarge!, 'Recent uploads'),
                _Type(
                  'subtitle / 16',
                  context.text.titleMedium!,
                  'Shared with me',
                ),
                _Type('body / 15', context.text.bodyLarge!, 'Q3 review.pdf'),
                _Type('label / 14', context.text.labelLarge!, 'Upload'),
                _Type(
                  'caption / 12.5',
                  context.text.bodySmall!,
                  '2.4 MB · 10:24',
                ),
              ],
            ),
          ),

          _Section(
            title: 'Buttons',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: Gap.xs,
                  runSpacing: Gap.xs,
                  children: [
                    NimbusButton(label: 'Primary', onPressed: () {}),
                    NimbusButton(
                      label: 'Secondary',
                      variant: NimbusButtonVariant.secondary,
                      onPressed: () {},
                    ),
                    NimbusButton(
                      label: 'Ghost',
                      variant: NimbusButtonVariant.ghost,
                      onPressed: () {},
                    ),
                    NimbusButton(
                      label: 'Delete',
                      variant: NimbusButtonVariant.danger,
                      icon: Icons.delete_outline_rounded,
                      onPressed: () {},
                    ),
                    const NimbusButton(label: 'Disabled'),
                  ],
                ),
                const SizedBox(height: Gap.sm),
                Wrap(
                  spacing: Gap.xs,
                  runSpacing: Gap.xs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    NimbusButton(
                      label: 'Small',
                      size: NimbusButtonSize.small,
                      variant: NimbusButtonVariant.secondary,
                      onPressed: () {},
                    ),
                    NimbusButton(label: 'Regular', onPressed: () {}),
                    NimbusButton(
                      label: 'Large',
                      size: NimbusButtonSize.large,
                      onPressed: () {},
                    ),
                  ],
                ),
                const SizedBox(height: Gap.sm),
                NimbusButton(
                  label: _loading
                      ? 'Uploading'
                      : 'Tap to see the loading state',
                  icon: Icons.arrow_upward_rounded,
                  expand: true,
                  loading: _loading,
                  onPressed: () async {
                    setState(() => _loading = true);
                    await Future<void>.delayed(const Duration(seconds: 2));
                    if (mounted) setState(() => _loading = false);
                  },
                ),
                const SizedBox(height: Gap.sm),
                Row(
                  children: [
                    NimbusIconButton(icon: Icons.add_rounded, onPressed: () {}),
                    const SizedBox(width: Gap.xs),
                    NimbusIconButton(
                      icon: Icons.arrow_downward_rounded,
                      onPressed: () {},
                    ),
                    const SizedBox(width: Gap.xs),
                    NimbusIconButton(
                      icon: Icons.ios_share_rounded,
                      background: AppColors.primary,
                      foreground: AppColors.onPrimary,
                      onPressed: () {},
                    ),
                    const SizedBox(width: Gap.xs),
                    NimbusIconButton(
                      icon: Icons.more_horiz_rounded,
                      background: AppColors.secondary,
                      foreground: Colors.white,
                      onPressed: () {},
                    ),
                  ],
                ),
              ],
            ),
          ),

          _Section(
            title: 'Selection',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                NimbusSegmented(
                  segments: const ['My files', 'Shared'],
                  selectedIndex: _segment,
                  onChanged: (i) => setState(() => _segment = i),
                  trailing: NimbusIconButton(
                    icon: Icons.sort_rounded,
                    size: 38,
                    onPressed: () {},
                  ),
                ),
                const SizedBox(height: Gap.md),
                Wrap(
                  spacing: Gap.xs,
                  runSpacing: Gap.xs,
                  children: [
                    for (var i = 0; i < 4; i++)
                      NimbusChip(
                        label: const ['All', 'Images', 'Video', 'Docs'][i],
                        count: const [247, 118, 32, 61][i],
                        selected: i == _chip,
                        accent: i == 0
                            ? null
                            : tokens.accentForType(
                                const ['', 'image', 'video', 'document'][i],
                              ),
                        onTap: () => setState(() => _chip = i),
                      ),
                  ],
                ),
              ],
            ),
          ),

          _Section(
            title: 'Cards',
            child: Column(
              children: [
                NimbusCard(
                  color: AppColors.secondary,
                  radius: Radii.xl,
                  padding: const EdgeInsets.all(Gap.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Uploaded this month',
                        style: context.text.titleMedium!.copyWith(
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: Gap.sm),
                      Text(
                        '8.5 GB',
                        style: context.text.displayLarge!.copyWith(
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: Gap.xxs),
                      Row(
                        children: [
                          const Icon(
                            Icons.arrow_upward_rounded,
                            size: 14,
                            color: Colors.white,
                          ),
                          const SizedBox(width: Gap.xxs),
                          Text(
                            '10.1% from last month',
                            style: context.text.bodySmall!.copyWith(
                              color: Colors.white.withValues(alpha: 0.75),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: Gap.xs),
                Row(
                  children: [
                    Expanded(
                      child: NimbusCard(
                        onTap: () {},
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Filled', style: context.text.titleMedium),
                            const SizedBox(height: Gap.xxs),
                            Text(
                              'Tap it',
                              style: context.text.bodySmall!.copyWith(
                                color: tokens.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: Gap.xs),
                    Expanded(
                      child: NimbusCard(
                        bordered: true,
                        color: Colors.transparent,
                        onTap: () {},
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Bordered', style: context.text.titleMedium),
                            const SizedBox(height: Gap.xxs),
                            Text(
                              'On canvas',
                              style: context.text.bodySmall!.copyWith(
                                color: tokens.textTertiary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          _Section(
            title: 'Rows',
            child: Column(
              children: [
                NimbusListRow(
                  title: 'Design assets',
                  subtitle: '48 files · 2.1 GB',
                  icon: Icons.folder_rounded,
                  iconColor: AppColors.primary,
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    color: tokens.textTertiary,
                  ),
                  onTap: () {},
                ),
                NimbusListRow(
                  title: 'contract-signed.pdf',
                  subtitle: '2.4 MB · encrypted',
                  icon: Icons.description_rounded,
                  iconColor: tokens.accentForType('document'),
                  trailing: const Text('10:24'),
                  trailingSubtitle: 'today',
                  onTap: () {},
                ),
                NimbusListRow(
                  title: 'Selected row',
                  subtitle: 'Long-press state',
                  icon: Icons.image_rounded,
                  iconColor: tokens.accentForType('image'),
                  selected: true,
                  trailing: const Icon(
                    Icons.check_circle_rounded,
                    color: AppColors.primary,
                    size: 22,
                  ),
                  onTap: () {},
                ),
              ],
            ),
          ),

          _Section(
            title: 'Input',
            child: Column(
              children: [
                TextField(
                  decoration: InputDecoration(
                    hintText: 'Search files and folders',
                    prefixIcon: Icon(
                      Icons.search_rounded,
                      color: tokens.textTertiary,
                      size: 20,
                    ),
                  ),
                ),
                const SizedBox(height: Gap.xs),
                const TextField(
                  decoration: InputDecoration(hintText: 'Focus me'),
                ),
              ],
            ),
          ),

          _Section(
            title: 'Radii',
            child: Row(
              children: [
                for (final (label, radius) in const [
                  ('xs', Radii.xs),
                  ('sm', Radii.sm),
                  ('md', Radii.md),
                  ('lg', Radii.lg),
                  ('xl', Radii.xl),
                  ('pill', Radii.pill),
                ])
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(right: Gap.xxs),
                      child: Column(
                        children: [
                          Container(
                            height: 52,
                            decoration: BoxDecoration(
                              color: tokens.raised,
                              borderRadius: BorderRadius.circular(radius),
                            ),
                          ),
                          const SizedBox(height: Gap.xxs),
                          Text(
                            label,
                            style: context.text.labelSmall!.copyWith(
                              color: tokens.textTertiary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title.toUpperCase(),
            style: context.text.labelSmall!.copyWith(
              color: context.tokens.textTertiary,
            ),
          ),
          const SizedBox(height: Gap.sm),
          child,
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch(
    this.label,
    this.color, {
    this.bordered = false,
    this.compact = false,
  });

  final String label;
  final Color color;
  final bool bordered;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.only(right: Gap.xxs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: compact ? 44 : 56,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(Radii.sm),
                border: bordered
                    ? Border.all(color: context.tokens.outlineStrong)
                    : null,
              ),
            ),
            const SizedBox(height: Gap.xxs),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.text.labelSmall!.copyWith(
                color: context.tokens.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Type extends StatelessWidget {
  const _Type(this.label, this.style, this.sample);

  final String label;
  final TextStyle style;
  final String sample;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: context.text.labelSmall!.copyWith(
              color: context.tokens.textTertiary,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            sample,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}
