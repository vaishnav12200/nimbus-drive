import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'app_dimens.dart';
import 'app_typography.dart';

/// Design tokens that Material's [ColorScheme] has no slot for.
///
/// Reached through `context.tokens`. Everything here is a *role* rather than a
/// colour name — `raised` instead of `grey900` — so a future light theme is a
/// second [NimbusTokens] instance and not an audit of every widget.
@immutable
class NimbusTokens extends ThemeExtension<NimbusTokens> {
  const NimbusTokens({
    required this.canvas,
    required this.surface,
    required this.raised,
    required this.raisedHigh,
    required this.floating,
    required this.outline,
    required this.outlineStrong,
    required this.skeleton,
    required this.skeletonSheen,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accents,
    required this.cardShadow,
    required this.floatingShadow,
  });

  final Color canvas;
  final Color surface;
  final Color raised;
  final Color raisedHigh;
  final Color floating;
  final Color outline;
  final Color outlineStrong;

  final Color skeleton;
  final Color skeletonSheen;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  /// The six category pastels, in the order they should be handed out to
  /// unnamed series (a chart, a folder colour picker).
  final List<Color> accents;

  final List<BoxShadow> cardShadow;
  final List<BoxShadow> floatingShadow;

  /// Colour for a backend file `type`, matching the values in `docs/API.md`.
  ///
  /// The mapping lives here so a document is the same yellow in the breakdown
  /// bar, the file row icon and the filter chip. Unknown types fall through to
  /// the "other" mint rather than throwing — the server may add a type before
  /// the client knows about it.
  Color accentForType(String type) => switch (type) {
    'image' => accents[0],
    'video' => accents[1],
    'document' => accents[2],
    'audio' => accents[3],
    'archive' => accents[4],
    _ => accents[5],
  };

  static const dark = NimbusTokens(
    canvas: AppColors.canvas,
    surface: AppColors.surface,
    raised: AppColors.surfaceRaised,
    raisedHigh: AppColors.surfaceHigh,
    floating: AppColors.surfaceFloating,
    outline: AppColors.outline,
    outlineStrong: AppColors.outlineStrong,
    skeleton: AppColors.skeleton,
    skeletonSheen: AppColors.skeletonSheen,
    textPrimary: AppColors.textPrimary,
    textSecondary: AppColors.textSecondary,
    textTertiary: AppColors.textTertiary,
    accents: [
      AppColors.accentBlue,
      AppColors.accentPurple,
      AppColors.accentYellow,
      AppColors.accentCoral,
      AppColors.accentCyan,
      AppColors.accentMint,
    ],
    // Shadows on a near-black canvas do almost nothing for depth; these exist
    // to soften the edge where a card meets the background, not to lift it.
    cardShadow: [
      BoxShadow(color: Color(0x40000000), blurRadius: 24, offset: Offset(0, 8)),
    ],
    floatingShadow: [
      BoxShadow(
        color: Color(0x66000000),
        blurRadius: 32,
        offset: Offset(0, 12),
      ),
    ],
  );

  @override
  NimbusTokens copyWith({
    Color? canvas,
    Color? surface,
    Color? raised,
    Color? raisedHigh,
    Color? floating,
    Color? outline,
    Color? outlineStrong,
    Color? skeleton,
    Color? skeletonSheen,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    List<Color>? accents,
    List<BoxShadow>? cardShadow,
    List<BoxShadow>? floatingShadow,
  }) {
    return NimbusTokens(
      canvas: canvas ?? this.canvas,
      surface: surface ?? this.surface,
      raised: raised ?? this.raised,
      raisedHigh: raisedHigh ?? this.raisedHigh,
      floating: floating ?? this.floating,
      outline: outline ?? this.outline,
      outlineStrong: outlineStrong ?? this.outlineStrong,
      skeleton: skeleton ?? this.skeleton,
      skeletonSheen: skeletonSheen ?? this.skeletonSheen,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      accents: accents ?? this.accents,
      cardShadow: cardShadow ?? this.cardShadow,
      floatingShadow: floatingShadow ?? this.floatingShadow,
    );
  }

  @override
  NimbusTokens lerp(covariant NimbusTokens? other, double t) {
    if (other == null) return this;
    return NimbusTokens(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surface: Color.lerp(surface, other.surface, t)!,
      raised: Color.lerp(raised, other.raised, t)!,
      raisedHigh: Color.lerp(raisedHigh, other.raisedHigh, t)!,
      floating: Color.lerp(floating, other.floating, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      outlineStrong: Color.lerp(outlineStrong, other.outlineStrong, t)!,
      skeleton: Color.lerp(skeleton, other.skeleton, t)!,
      skeletonSheen: Color.lerp(skeletonSheen, other.skeletonSheen, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textTertiary: Color.lerp(textTertiary, other.textTertiary, t)!,
      accents: [
        for (var i = 0; i < accents.length; i++)
          Color.lerp(accents[i], other.accents[i], t)!,
      ],
      cardShadow: BoxShadow.lerpList(cardShadow, other.cardShadow, t)!,
      floatingShadow: BoxShadow.lerpList(
        floatingShadow,
        other.floatingShadow,
        t,
      )!,
    );
  }
}

extension NimbusThemeAccess on BuildContext {
  /// Nimbus-specific tokens. Falls back to [NimbusTokens.dark] so a widget
  /// rendered in a bare `MaterialApp` (a golden test, a `flutter create`
  /// harness) still draws instead of throwing on a null extension.
  NimbusTokens get tokens =>
      Theme.of(this).extension<NimbusTokens>() ?? NimbusTokens.dark;

  TextTheme get text => Theme.of(this).textTheme;

  ColorScheme get colors => Theme.of(this).colorScheme;
}

/// Scroll physics used app-wide.
///
/// Overscroll bounces on every platform, not just iOS. On a dark UI with large
/// rounded cards, Android's glow clips against the corners and looks broken;
/// the bounce reads as intentional everywhere.
class NimbusScrollBehavior extends MaterialScrollBehavior {
  const NimbusScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}

abstract final class AppTheme {
  static ThemeData get dark {
    const tokens = NimbusTokens.dark;

    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.dark,
      // Every role the app actually uses is pinned. Whatever the algorithm
      // derives for the rest is unreachable, and pinning these means the lime
      // stays the exact sampled hue instead of being tonally "corrected".
      primary: AppColors.primary,
      onPrimary: AppColors.onPrimary,
      secondary: AppColors.secondary,
      onSecondary: Colors.white,
      surface: tokens.canvas,
      onSurface: tokens.textPrimary,
      surfaceContainerLowest: tokens.canvas,
      surfaceContainerLow: tokens.surface,
      surfaceContainer: tokens.raised,
      surfaceContainerHigh: tokens.raisedHigh,
      outline: tokens.outline,
      outlineVariant: tokens.outlineStrong,
      error: AppColors.danger,
    );

    final textTheme = AppTypography.textTheme();

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      textTheme: textTheme,
      scaffoldBackgroundColor: tokens.canvas,
      canvasColor: tokens.canvas,
      fontFamily: AppTypography.fontFamily,
      extensions: const [tokens],

      // Material's ink ripple fights the reference's iOS-flavoured feel. Press
      // feedback comes from `Pressable`'s scale instead, so the splash is
      // removed globally rather than opted out of per widget.
      splashFactory: NoSplash.splashFactory,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      hoverColor: Colors.white.withValues(alpha: 0.03),

      appBarTheme: AppBarTheme(
        backgroundColor: tokens.canvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        titleTextStyle: AppTypography.subtitle.copyWith(
          color: tokens.textPrimary,
        ),
        iconTheme: IconThemeData(color: tokens.textPrimary, size: 22),
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),

      dividerTheme: DividerThemeData(
        color: tokens.outline,
        thickness: 1,
        space: 1,
      ),

      iconTheme: IconThemeData(color: tokens.textPrimary, size: 22),

      // Widgets below are styled so that framework-provided surfaces (a
      // date picker, a snackbar from a service layer) match hand-built ones.
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: tokens.surface,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: tokens.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.xxl)),
        ),
        showDragHandle: true,
        dragHandleColor: tokens.outlineStrong,
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: tokens.raised,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        titleTextStyle: AppTypography.title.copyWith(color: tokens.textPrimary),
        contentTextStyle: AppTypography.body.copyWith(
          color: tokens.textSecondary,
        ),
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: tokens.raisedHigh,
        contentTextStyle: AppTypography.bodyStrong.copyWith(
          color: tokens.textPrimary,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.md),
        ),
        insetPadding: const EdgeInsets.all(Gap.md),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: tokens.raised,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Gap.md,
          vertical: Gap.md,
        ),
        hintStyle: AppTypography.body.copyWith(color: tokens.textTertiary),
        // A transparent border at the same width as the focused one keeps the
        // field from resizing by a pixel when it gains focus.
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: const BorderSide(color: Colors.transparent, width: 1.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: const BorderSide(color: Colors.transparent, width: 1.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: const BorderSide(color: AppColors.primary, width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: const BorderSide(color: AppColors.danger, width: 1.5),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.md),
          borderSide: const BorderSide(color: AppColors.danger, width: 1.5),
        ),
      ),

      // A horizontal slide on every platform. Android keeps the predictive-back
      // builder rather than being forced into the iOS one — swiping back is a
      // system gesture there, and overriding it costs more than the visual
      // consistency is worth.
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }
}
