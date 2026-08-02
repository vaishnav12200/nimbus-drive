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

  /// Loading placeholder blocks. One tone above [surfaceRaised] so a skeleton
  /// is visible whether it sits on the page or inside the card it is loading
  /// into.
  static const skeleton = Color(0xFF2E2E2E);

  /// The travelling highlight swept across [skeleton]. Far enough above it to
  /// be seen in motion without turning the placeholder into a light band.
  static const skeletonSheen = Color(0xFF454545);

  // --- Text -----------------------------------------------------------------
  //
  // Every value below clears WCAG AA (4.5:1) against *both* `canvas` and
  // `surfaceRaised`, checked rather than eyeballed. Raised is the harder case
  // and the one that gets forgotten: a caption is legible on the page and then
  // moves inside a card and is not.

  /// 19.0:1 on canvas.
  static const textPrimary = Color(0xFFFFFFFF);

  /// 8.3:1 on canvas, 6.8:1 on raised.
  static const textSecondary = Color(0xFFABABAB);

  /// 5.5:1 on canvas, 4.6:1 on raised.
  ///
  /// The dimmest grey the system allows. It was #6B6B6B, sampled from the
  /// reference, which measured 2.95:1 on raised — the reference uses it for
  /// decorative labels, but here it carries file sizes and timestamps, which
  /// are content.
  static const textTertiary = Color(0xFF8A8A8A);

  /// Text and icons placed on top of [primary].
  static const onPrimary = Color(0xFF0A0A0A);

  /// Text and icons on top of any [accentBlue]-family pastel. All six are
  /// light enough that black clears 8:1 on every one of them; white clears
  /// none. There is no second ink colour in this system by design.
  static const onAccent = Color(0xFF0A0A0A);

  // --- Brand ----------------------------------------------------------------

  /// The signature lime. Primary actions, the hero card, the active nav pill.
  ///
  /// Used sparingly: one lime element per viewport is what makes it read as
  /// emphasis. Two is decoration.
  static const primary = Color(0xFF98EF5A);
  static const primaryDim = Color(0xFF7ACC42);

  /// Analytics, storage insight, anything informational rather than actionable.
  ///
  /// The reference's purple is #935AEF, which puts white text at 4.24:1 —
  /// just under AA, and this colour exists to be a card with white text on it.
  /// Darkened ~5% to clear it at 5.1:1. The difference is invisible beside the
  /// original; the failure was not.
  ///
  /// One purple, not two. A "safe" and an "unsafe" variant of the same hue is
  /// a trap — the wrong one gets picked eventually.
  static const secondary = Color(0xFF8250DE);
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

  /// Takes [onAccent], not white — white on this red is 2.78:1, black is
  /// 7.1:1. A destructive button is the last place to accept unreadable text.
  static const danger = Color(0xFFFF6B6B);
}
