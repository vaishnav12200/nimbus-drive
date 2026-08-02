import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_dimens.dart';

/// Tap target that shrinks slightly while held.
///
/// This is the single source of press feedback in the app — Material's ink
/// splash is disabled globally in [AppTheme]. Routing every tappable through
/// one widget means the timing is identical everywhere, which is most of why
/// the reference feels calm: nothing responds at its own speed.
///
/// The shrink is driven by an [AnimationController] rather than an
/// [AnimatedScale] so that releasing mid-press reverses from wherever the
/// animation currently is instead of snapping to the end first.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = Motion.pressScale,
    this.haptic = true,
    this.borderRadius,
    this.behavior = HitTestBehavior.opaque,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Scale at full press. Larger elements should shrink *less*, not more — a
  /// full-width card at 0.97 travels far more pixels than a chip does.
  final double scale;

  /// Selection click on tap. Turned off for high-frequency targets like
  /// keypad keys, where per-tap haptics become noise.
  final bool haptic;

  /// Clips the child while pressed. Only needed when the child paints to its
  /// own edges (an image, a filled card).
  final BorderRadius? borderRadius;

  final HitTestBehavior behavior;

  bool get _enabled => onTap != null || onLongPress != null;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Motion.fast,
    reverseDuration: Motion.normal,
  );

  late final Animation<double> _scale = _controller.drive(
    Tween<double>(begin: 1, end: widget.scale).chain(
      // Press in quickly, release with the softer default curve — a release
      // that eases out feels like the finger let go, not like a rebound.
      CurveTween(curve: Motion.decelerate),
    ),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _down(TapDownDetails _) => _controller.forward();

  void _up([TapUpDetails? _]) => _controller.reverse();

  void _tap() {
    if (widget.haptic) HapticFeedback.selectionClick();
    widget.onTap?.call();
  }

  void _longPress() {
    if (widget.haptic) HapticFeedback.mediumImpact();
    widget.onLongPress?.call();
  }

  @override
  Widget build(BuildContext context) {
    Widget child = ScaleTransition(scale: _scale, child: widget.child);

    if (widget.borderRadius != null) {
      child = ClipRRect(borderRadius: widget.borderRadius!, child: child);
    }

    if (!widget._enabled) return child;

    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: _down,
      onTapUp: _up,
      onTapCancel: _up,
      onTap: widget.onTap == null ? null : _tap,
      onLongPress: widget.onLongPress == null ? null : _longPress,
      child: MouseRegion(cursor: SystemMouseCursors.click, child: child),
    );
  }
}
