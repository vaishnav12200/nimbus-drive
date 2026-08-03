import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';
import 'pressable.dart';

@immutable
class BreakdownSegment {
  const BreakdownSegment({
    required this.label,
    required this.value,
    required this.color,
    this.trailing,
  });

  final String label;

  /// Any unit — the widget only ever uses these relative to their sum, so
  /// bytes, counts and percentages all work without conversion.
  final double value;

  final Color color;

  /// Text shown at the pill's right edge. Defaults to a rounded percentage.
  final String? trailing;
}

/// Proportional category rows — the reference's spending breakdown, reused
/// here for storage by file type.
///
/// Each row is a pill whose width encodes its share. Rows grow from zero on
/// first build, which is what makes the section feel like it is reporting
/// something rather than just being drawn.
class NimbusBreakdown extends StatelessWidget {
  const NimbusBreakdown({
    super.key,
    required this.segments,
    this.onSegmentTap,
    this.rowHeight = 46,
    this.minFraction = 0.38,
  });

  final List<BreakdownSegment> segments;
  final void Function(BreakdownSegment segment)? onSegmentTap;
  final double rowHeight;

  /// Floor on a row's width as a fraction of the container.
  ///
  /// Without it a 2% category collapses to a sliver that cannot fit its own
  /// label — at phone width the label is dropped entirely, since it is the
  /// flexible child. The default is tuned so a row still holds one word on a
  /// 390pt screen; the value moves outside the bar when it will not fit
  /// alongside, so the floor only has to cover the label.
  ///
  /// The bars stay honest in order and rank; only the extreme low end is
  /// clamped, which is the trade every version of this chart makes. Read the
  /// trailing value, not the width, for a precise figure.
  final double minFraction;

  @override
  Widget build(BuildContext context) {
    final total = segments.fold<double>(0, (sum, s) => sum + s.value);
    if (total <= 0) return const SizedBox.shrink();

    final max = segments.fold<double>(0, (m, s) => s.value > m ? s.value : m);

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < segments.length; i++) ...[
              if (i > 0) const SizedBox(height: Gap.xs),
              _Row(
                segment: segments[i],
                width:
                    available *
                    (minFraction +
                        (1 - minFraction) *
                            (max == 0 ? 0 : segments[i].value / max)),
                percent: segments[i].value / total,
                height: rowHeight,
                // Stagger so the rows cascade instead of arriving as a block.
                delay: Duration(milliseconds: 60 * i),
                onTap: onSegmentTap == null
                    ? null
                    : () => onSegmentTap!(segments[i]),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({
    required this.segment,
    required this.width,
    required this.percent,
    required this.height,
    required this.delay,
    this.onTap,
  });

  final BreakdownSegment segment;
  final double width;
  final double percent;
  final double height;
  final Duration delay;
  final VoidCallback? onTap;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  double _width = 0;

  /// Held so it can be cancelled. A `mounted` check inside the callback stops
  /// the setState but leaves the timer itself pending, which leaks past a
  /// disposed widget and trips the test binding's timer check.
  Timer? _entrance;

  @override
  void initState() {
    super.initState();
    // Grow-in runs once per mount. Later width changes (a filter narrowing the
    // set) animate through the same AnimatedContainer without re-triggering.
    _entrance = Timer(widget.delay, () {
      if (mounted) setState(() => _width = widget.width);
    });
  }

  @override
  void dispose() {
    _entrance?.cancel();
    super.dispose();
  }

  @override
  void didUpdateWidget(_Row old) {
    super.didUpdateWidget(old);
    if (old.width != widget.width && _width != 0) {
      setState(() => _width = widget.width);
    }
  }

  /// Rendered width of [text] in [style], for deciding whether it fits.
  double _measure(String text, TextStyle style, double scale) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: TextScaler.linear(scale),
    )..layout();
    return painter.width;
  }

  @override
  Widget build(BuildContext context) {
    final segment = widget.segment;
    final trailing = segment.trailing ?? '${(widget.percent * 100).round()}%';

    // Every pastel in the palette is light, so black is the legible choice on
    // all of them.
    final labelStyle = context.text.bodyLarge!.copyWith(
      color: Colors.black,
      fontWeight: FontWeight.w500,
    );
    final valueStyle = context.text.bodySmall!;

    // Does the value fit inside the bar next to the label?
    //
    // A byte size ("13.4 MB") is far wider than the percentage the reference
    // shows, and the shortest bars are clamped to a fixed minimum — so on a
    // narrow screen the label was being ellipsised away to make room. Measuring
    // lets the value move outside the bar in exactly those cases instead of
    // forcing every bar wider and flattening the chart.
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final needed =
        _measure(segment.label, labelStyle, scale) +
        Gap.xs +
        _measure(trailing, valueStyle, scale) +
        Gap.md * 2;
    // Compared against the *target* width, not the animating one, so the
    // decision does not flip part-way through the grow-in.
    final fitsInside = needed <= widget.width;

    Widget value(Color color) =>
        Text(trailing, style: valueStyle.copyWith(color: color));

    final bar = AnimatedContainer(
      duration: Motion.slow,
      curve: Motion.emphasized,
      width: _width,
      height: widget.height,
      padding: const EdgeInsets.symmetric(horizontal: Gap.md),
      decoration: BoxDecoration(
        color: segment.color,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              segment.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: labelStyle,
            ),
          ),
          if (fitsInside) ...[
            const SizedBox(width: Gap.xs),
            value(Colors.black.withValues(alpha: 0.55)),
          ],
        ],
      ),
    );

    return Pressable(
      onTap: widget.onTap,
      scale: 0.98,
      child: fitsInside
          ? bar
          : Row(
              children: [
                bar,
                const SizedBox(width: Gap.xs),
                Flexible(child: value(context.tokens.textSecondary)),
              ],
            ),
    );
  }
}

/// Single-row stacked bar — total storage split by type.
///
/// Complements [NimbusBreakdown]: this answers "how full", that one answers
/// "full of what".
class NimbusStackedBar extends StatelessWidget {
  const NimbusStackedBar({
    super.key,
    required this.segments,
    this.height = 10,
    this.track,
    this.freeFraction = 0,
  });

  final List<BreakdownSegment> segments;
  final double height;
  final Color? track;

  /// Share of the bar left empty, drawn in [track]. Zero means the segments
  /// fill the width regardless of their absolute total.
  final double freeFraction;

  @override
  Widget build(BuildContext context) {
    final total = segments.fold<double>(0, (sum, s) => sum + s.value);
    if (total <= 0) return const SizedBox.shrink();

    final used = (1 - freeFraction).clamp(0.0, 1.0);

    return ClipRRect(
      borderRadius: BorderRadius.circular(Radii.pill),
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            for (final segment in segments)
              Expanded(
                flex: ((segment.value / total) * used * 10000).round().clamp(
                  1,
                  1 << 30,
                ),
                child: Padding(
                  // A hairline gap keeps adjacent pastels from reading as one
                  // muddy band.
                  padding: const EdgeInsets.only(right: 2),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: segment.color,
                      borderRadius: BorderRadius.circular(Radii.pill),
                    ),
                  ),
                ),
              ),
            if (freeFraction > 0)
              Expanded(
                flex: (freeFraction * 10000).round().clamp(1, 1 << 30),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: track ?? context.tokens.raisedHigh,
                    borderRadius: BorderRadius.circular(Radii.pill),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
