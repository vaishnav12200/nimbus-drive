import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Type scale.
///
/// Inter is bundled rather than fetched at runtime, so the first frame after a
/// cold install renders in the real typeface instead of a fallback that reflows
/// a moment later.
///
/// Two habits from the reference are encoded here:
///
/// * **Large text tracks tighter.** Inter is drawn with generous spacing that
///   looks slack above ~24px, so [display] and [headline] pull it back in.
/// * **Numerals are tabular.** Sizes, counts and percentages sit in columns and
///   change while you watch them; proportional digits make that shimmer.
abstract final class AppTypography {
  static const String fontFamily = 'Inter';

  static const List<FontFeature> _tabular = [FontFeature.tabularFigures()];

  /// The hero number on a storage or usage card. One per screen, at most.
  static const TextStyle display = TextStyle(
    fontFamily: fontFamily,
    fontSize: 44,
    height: 1.05,
    fontWeight: FontWeight.w700,
    letterSpacing: -1.6,
    fontFeatures: _tabular,
  );

  /// Screen titles on scroll-away headers.
  static const TextStyle headline = TextStyle(
    fontFamily: fontFamily,
    fontSize: 28,
    height: 1.15,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.8,
  );

  /// Section headings — "Recent files", "Storage".
  static const TextStyle title = TextStyle(
    fontFamily: fontFamily,
    fontSize: 19,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.4,
  );

  /// App bar titles and emphasised row labels.
  static const TextStyle subtitle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 16,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
  );

  /// Default reading size. File names, descriptions.
  static const TextStyle body = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    height: 1.4,
    fontWeight: FontWeight.w400,
    letterSpacing: -0.1,
  );

  /// Body weight bumped for a row's primary line.
  static const TextStyle bodyStrong = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    height: 1.4,
    fontWeight: FontWeight.w500,
    letterSpacing: -0.1,
  );

  /// Buttons, chips, tabs.
  static const TextStyle label = TextStyle(
    fontFamily: fontFamily,
    fontSize: 14,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
  );

  /// Secondary line under a file name: size, modified date.
  static const TextStyle caption = TextStyle(
    fontFamily: fontFamily,
    fontSize: 12.5,
    height: 1.3,
    fontWeight: FontWeight.w500,
    fontFeatures: _tabular,
  );

  /// Nav bar labels, badge counts. Uppercase-friendly.
  static const TextStyle overline = TextStyle(
    fontFamily: fontFamily,
    fontSize: 11,
    height: 1.2,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.3,
  );

  /// Maps the scale onto Material's slots so unstyled framework widgets
  /// (dialogs, snackbars, menus) inherit it instead of falling back to Roboto.
  static TextTheme textTheme() {
    const primary = AppColors.textPrimary;
    const secondary = AppColors.textSecondary;

    return const TextTheme(
      displayLarge: display,
      displayMedium: display,
      displaySmall: headline,
      headlineLarge: headline,
      headlineMedium: headline,
      headlineSmall: title,
      titleLarge: title,
      titleMedium: subtitle,
      titleSmall: label,
      bodyLarge: body,
      bodyMedium: body,
      bodySmall: caption,
      labelLarge: label,
      labelMedium: label,
      labelSmall: overline,
    ).apply(
      bodyColor: primary,
      displayColor: primary,
      decorationColor: secondary,
    );
  }
}
