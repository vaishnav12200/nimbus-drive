import 'package:flutter/painting.dart';

/// Raw colour tokens.
///
/// Values were sampled from the reference shot rather than eyeballed, so the
/// lime and the purple are the exact hues the design uses, not approximations.
///
/// Nothing outside `app_theme.dart` should reach in here. Widgets read colours
/// from `Theme.of(context)` or `context.tokens`, which keeps a second palette
/// (a light theme, a white-label build) a swap rather than a rewrite.
abstract final class AppColors {
  // --- Neutrals -------------------------------------------------------------
  // The canvas is deliberately not pure black: on OLED, black next to a
  // saturated lime reads as a hole rather than a surface.

  /// Page background, behind everything.
  static const canvas = Color(0xFF101010);

  /// Slightly lifted background for grouped regions and sheets.
  static const surface = Color(0xFF161616);

  /// Cards, list rows, keypad keys — the default "thing on the page".
  static const surfaceRaised = Color(0xFF232323);

  /// Pressed and hovered states of `surfaceRaised`.
  static const surfaceHigh = Color(0xFF2E2E2E);

  /// Floating bars that sit above content and need to feel detached.
  static const surfaceFloating = Color(0xFF151515);

  /// Hairline dividers and card borders. Barely visible by design.
  static const outline = Color(0xFF2A2A2A);

  /// Borders on interactive surfaces that need to read as an edge.
  static const outlineStrong = Color(0xFF3A3A3A);

  // --- Text -----------------------------------------------------------------

  static const textPrimary = Color(0xFFFFFFFF);
  static const textSecondary = Color(0xFF9A9A9A);
  static const textTertiary = Color(0xFF6B6B6B);

  /// Text and icons placed on top of [primary].
  static const onPrimary = Color(0xFF0A0A0A);

  // --- Brand ----------------------------------------------------------------

  /// The signature lime. Primary actions, the hero card, the active nav pill.
  ///
  /// Used sparingly: one lime element per viewport is what makes it read as
  /// emphasis. Two is decoration.
  static const primary = Color(0xFF98EF5A);
  static const primaryDim = Color(0xFF7ACC42);

  /// Analytics, storage insight, anything informational rather than actionable.
  static const secondary = Color(0xFF935AEF);
  static const secondaryDim = Color(0xFF7A45D1);

  // --- Category accents -----------------------------------------------------
  // Six pastels, one per file type. They carry meaning, so the mapping in
  // `NimbusTokens.categoryFor` is the single place it is decided.

  static const accentBlue = Color(0xFF89B2FF); // images
  static const accentPurple = Color(0xFFD2A4FF); // video
  static const accentYellow = Color(0xFFFFED89); // documents
  static const accentCoral = Color(0xFFFF8989); // audio
  static const accentCyan = Color(0xFF89FFF9); // archives
  static const accentMint = Color(0xFF89FFC0); // other

  // --- Status ---------------------------------------------------------------

  static const success = Color(0xFF89FFC0);
  static const warning = Color(0xFFFFED89);
  static const danger = Color(0xFFFF6B6B);
}
