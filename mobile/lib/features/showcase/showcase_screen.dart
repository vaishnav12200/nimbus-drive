import 'package:flutter/material.dart';

import '../../core/theme/app_dimens.dart';
import '../../core/widgets/nimbus_nav_bar.dart';
import 'overview_page.dart';
import 'style_guide_page.dart';

/// Temporary harness for reviewing the design system.
///
/// Two pages: a realistic drive screen assembled from the shared widgets, and
/// a style guide listing them in isolation. Both exist to be looked at — this
/// whole directory is deleted once the real feature screens land, and nothing
/// under `core/` may import from it.
class ShowcaseScreen extends StatefulWidget {
  const ShowcaseScreen({super.key});

  @override
  State<ShowcaseScreen> createState() => _ShowcaseScreenState();
}

class _ShowcaseScreenState extends State<ShowcaseScreen> {
  static const _items = [
    NimbusNavItem(icon: Icons.grid_view_rounded, label: 'Overview'),
    NimbusNavItem(icon: Icons.folder_rounded, label: 'Files'),
    NimbusNavItem(icon: Icons.add_rounded, label: 'Upload'),
    NimbusNavItem(icon: Icons.link_rounded, label: 'Shared'),
    NimbusNavItem(icon: Icons.palette_outlined, label: 'Style guide'),
  ];

  int _index = 0;

  @override
  Widget build(BuildContext context) {
    // Only the first and last tabs have content; the middle three are here so
    // the bar has the reference's five slots and its travel can be judged.
    final page = _index == _items.length - 1
        ? const StyleGuidePage()
        : const OverviewPage();

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: Motion.normal,
              switchInCurve: Motion.decelerate,
              switchOutCurve: Motion.accelerate,
              child: KeyedSubtree(
                key: ValueKey(_index == _items.length - 1),
                child: page,
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: NimbusNavBar(
              items: _items,
              currentIndex: _index,
              onChanged: (i) => setState(() => _index = i),
            ),
          ),
        ],
      ),
    );
  }
}
