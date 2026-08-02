import 'package:flutter/widgets.dart';

/// Spacing scale.
///
/// A 4pt grid with the mid-range filled in, because that is where layout
/// actually happens. Using the scale instead of literals is what keeps two
/// screens built a week apart looking like the same app.
abstract final class Gap {
  static const double xxs = 4;
  static const double xs = 8;
  static const double sm = 12;
  static const double md = 16;
  static const double lg = 20;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 40;

  /// Horizontal page margin. Every screen uses this and nothing else.
  static const double page = 20;
}

/// Corner radii.
///
/// The reference leans hard on large radii and true pills; that softness is
/// most of its character, so the scale starts where a conventional one ends.
abstract final class Radii {
  static const double xs = 10;
  static const double sm = 14;
  static const double md = 18;
  static const double lg = 24;
  static const double xl = 28;
  static const double xxl = 34;

  /// Fully rounded. Any value past half the height gets clamped by the
  /// framework, so this is safe on arbitrary sizes.
  static const double pill = 999;
}

/// Motion tokens.
///
/// The "smoothness" of the reference is mostly timing. Two rules hold the
/// system together: nothing animates longer than [slow], and everything
/// entering or settling uses [decelerate] so it arrives softly instead of
/// stopping dead.
abstract final class Motion {
  /// Colour and opacity changes on press. Fast enough to feel instant.
  static const Duration fast = Duration(milliseconds: 120);

  /// The default. Scale on tap, size changes, cross-fades.
  static const Duration normal = Duration(milliseconds: 220);

  /// Sheets, page transitions, anything travelling a long distance.
  static const Duration slow = Duration(milliseconds: 380);

  /// Elements arriving or settling. Fast start, soft landing.
  static const Curve decelerate = Curves.easeOutCubic;

  /// Elements leaving. Mirror of [decelerate].
  static const Curve accelerate = Curves.easeInCubic;

  /// Movement with a start and an end, both visible — sheets, reorders.
  static const Curve emphasized = Curves.easeInOutCubicEmphasized;

  /// How far a pressable shrinks. Small: the cue should be felt, not watched.
  static const double pressScale = 0.97;

  /// Whether the user has asked the OS to reduce motion.
  ///
  /// Flutter surfaces "Remove animations" (Android) and "Reduce Motion" (iOS)
  /// as [MediaQueryData.disableAnimations]. It does *not* act on it for you:
  /// an explicit [AnimationController] keeps running regardless. A design
  /// built on movement therefore has to ask.
  static bool reduced(BuildContext context) =>
      MediaQuery.maybeDisableAnimationsOf(context) ?? false;

  /// [duration], or zero when the user has asked for less motion.
  ///
  /// Zero rather than merely shorter: the setting exists for people whose
  /// symptoms a faster animation does not help. Colour and layout still land
  /// on the same final frame, so nothing is lost but the travel.
  static Duration of(BuildContext context, Duration duration) =>
      reduced(context) ? Duration.zero : duration;
}
