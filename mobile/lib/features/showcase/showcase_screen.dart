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
  /// The app's real destinations. Profile is deliberately absent — it lives in
  /// the top-right of the header, so the bar is five places to *go* rather than
  /// four places and an account button.
  static const _items = [
    NimbusNavItem(icon: Icons.home_rounded, label: 'Home'),
    NimbusNavItem(icon: Icons.folder_rounded, label: 'Files'),
    NimbusNavItem(icon: Icons.arrow_upward_rounded, label: 'Upload'),
    NimbusNavItem(icon: Icons.link_rounded, label: 'Shared'),
    NimbusNavItem(icon: Icons.settings_rounded, label: 'Settings'),
  ];

  int _index = 0;

  @override
  Widget build(BuildContext context) {
    // Only Home is built. Files, Upload and Shared switch the pill and show
    // Home until their screens land. Settings stands in for the style guide
    // during review — the guide is not a destination and goes away with this
    // directory.
    final page = _index == 4 ? const StyleGuidePage() : const OverviewPage();

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: Motion.of(context, Motion.normal),
              switchInCurve: Motion.decelerate,
              switchOutCurve: Motion.accelerate,
              child: KeyedSubtree(key: ValueKey(_index == 4), child: page),
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
