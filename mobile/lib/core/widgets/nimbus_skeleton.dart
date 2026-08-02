import 'package:flutter/material.dart';

import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';

/// Shimmering placeholder block.
///
/// Used while a file list, a folder or a storage figure is loading. A skeleton
/// beats a spinner here because the layout is already known — the page does not
/// jump when the data lands, and the shape itself says what is coming.
///
/// One controller drives every descendant via [NimbusSkeletonGroup], so twenty
/// rows shimmer in phase instead of twenty independent tickers drifting apart.
class NimbusSkeleton extends StatelessWidget {
  const NimbusSkeleton({
    super.key,
    this.width,
    this.height = 14,
    this.radius = Radii.xs,
    this.shape = BoxShape.rectangle,
  });

  /// Circular variant for avatars and icon tiles. [width] is required and
  /// [height] ignored, since a circle has one dimension.
  const NimbusSkeleton.circle({super.key, required double size})
    : width = size,
      height = size,
      radius = 0,
      shape = BoxShape.circle;

  final double? width;
  final double height;
  final double radius;
  final BoxShape shape;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final t = NimbusSkeletonGroup.phaseOf(context);

    // Its own token, not `raised`: a skeleton is as likely to sit inside a
    // card as on the page, and at `raised` it is invisible against the card it
    // is loading into.
    final base = tokens.skeleton;
    final highlight = tokens.skeletonSheen;

    // A travelling highlight rather than a pulsing opacity: a whole screen
    // fading in and out together is far more distracting than a sweep.
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: base,
        shape: shape,
        borderRadius: shape == BoxShape.circle
            ? null
            : BorderRadius.circular(radius),
        gradient: t == null
            ? null
            : LinearGradient(
                begin: Alignment(-1 - 2 * (1 - t), 0),
                end: Alignment(1 - 2 * (1 - t), 0),
                colors: [base, highlight, base],
                stops: const [0.2, 0.5, 0.8],
              ),
      ),
    );
  }
}

/// Drives the shimmer for every [NimbusSkeleton] beneath it.
///
/// Wrap the loading region once. Without it skeletons still render, just
/// flat — which is also what happens, deliberately, when the user has asked
/// the OS to reduce motion.
class NimbusSkeletonGroup extends StatefulWidget {
  const NimbusSkeletonGroup({
    super.key,
    required this.child,
    this.period = const Duration(milliseconds: 1400),
  });

  final Widget child;
  final Duration period;

  /// Current sweep position in 0..1, or null when nothing should shimmer.
  static double? phaseOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SkeletonPhase>()?.phase;

  @override
  State<NimbusSkeletonGroup> createState() => _NimbusSkeletonGroupState();
}

class _NimbusSkeletonGroupState extends State<NimbusSkeletonGroup>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.period,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Re-evaluated on every dependency change so toggling the OS setting while
    // the app is open takes effect without a restart.
    if (Motion.reduced(context)) {
      _controller.stop();
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Motion.reduced(context)) {
      return _SkeletonPhase(phase: null, child: widget.child);
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) =>
          _SkeletonPhase(phase: _controller.value, child: child!),
      child: widget.child,
    );
  }
}

class _SkeletonPhase extends InheritedWidget {
  const _SkeletonPhase({required this.phase, required super.child});

  final double? phase;

  @override
  bool updateShouldNotify(_SkeletonPhase old) => old.phase != phase;
}

/// Placeholder shaped like a [NimbusListRow], for a file list that has not
/// arrived yet.
class NimbusRowSkeleton extends StatelessWidget {
  const NimbusRowSkeleton({super.key, this.titleWidth = 160});

  final double titleWidth;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Gap.sm,
        vertical: Gap.sm - 2,
      ),
      child: Row(
        children: [
          const NimbusSkeleton(width: 44, height: 44, radius: Radii.sm),
          const SizedBox(width: Gap.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NimbusSkeleton(width: titleWidth, height: 13),
              const SizedBox(height: Gap.xs),
              const NimbusSkeleton(width: 90, height: 11),
            ],
          ),
        ],
      ),
    );
  }
}
