import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Account avatar, with an initials fallback.
///
/// Most accounts here sign in with email and have no picture, so the fallback
/// is the common case rather than the edge one. The colour is derived from the
/// name so the same person is the same colour on every screen without anything
/// being stored.
class NimbusAvatar extends StatelessWidget {
  const NimbusAvatar({
    super.key,
    required this.name,
    this.imageUrl,
    this.size = 44,
    this.ringColor,
  });

  final String name;
  final String? imageUrl;
  final double size;

  /// Draws a ring in the page background colour, which reads as a gap rather
  /// than a border when avatars overlap in a stack.
  final Color? ringColor;

  /// First letters of the first two words: "Vaishnav K M" becomes "VK".
  String get _initials {
    final words = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    if (words.isEmpty) return '?';
    return words.take(2).map((w) => w.characters.first.toUpperCase()).join();
  }

  /// Deterministic pick from the palette. Not cryptographic — it only has to
  /// be stable and evenly spread.
  Color get _color {
    if (name.isEmpty) return AppColors.secondary;
    final hash = name.codeUnits.fold<int>(
      0,
      (h, c) => (h * 31 + c) & 0x7FFFFFFF,
    );
    return _palette[hash % _palette.length];
  }

  static const _palette = [
    AppColors.secondary,
    AppColors.accentBlue,
    AppColors.accentPurple,
    AppColors.accentCoral,
    AppColors.accentCyan,
    AppColors.accentMint,
  ];

  @override
  Widget build(BuildContext context) {
    final background = _color;

    // Every pastel in the palette takes black ink; only the purple takes
    // white. Deciding by luminance rather than by listing the exceptions
    // keeps this correct if the palette grows.
    final foreground = background.computeLuminance() > 0.4
        ? AppColors.onAccent
        : Colors.white;

    Widget child = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: background,
        shape: BoxShape.circle,
        image: imageUrl == null
            ? null
            : DecorationImage(
                image: NetworkImage(imageUrl!),
                fit: BoxFit.cover,
              ),
      ),
      child: imageUrl != null
          ? null
          : Text(
              _initials,
              style: context.text.titleMedium!.copyWith(
                color: foreground,
                fontSize: size * 0.36,
              ),
            ),
    );

    if (ringColor != null) {
      child = Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: ringColor!, width: 2),
        ),
        child: child,
      );
    }

    return Semantics(label: name, image: true, child: child);
  }
}
