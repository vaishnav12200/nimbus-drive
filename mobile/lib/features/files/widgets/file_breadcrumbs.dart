import 'package:flutter/material.dart';

import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/pressable.dart';
import '../models/drive_item.dart';

/// Root › Design assets › Archive 2025
///
/// Scrolls horizontally and pins itself to the end, because the crumb that
/// matters is the one you are standing in — a deep path that scrolls to show
/// "Root" first hides the only useful part.
class FileBreadcrumbs extends StatefulWidget {
  const FileBreadcrumbs({super.key, required this.trail, required this.onTap});

  final List<DriveFolder> trail;

  /// -1 for the root crumb, otherwise the index within [trail].
  final ValueChanged<int> onTap;

  @override
  State<FileBreadcrumbs> createState() => _FileBreadcrumbsState();
}

class _FileBreadcrumbsState extends State<FileBreadcrumbs> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(FileBreadcrumbs old) {
    super.didUpdateWidget(old);
    if (old.trail.length != widget.trail.length) _pinToEnd();
  }

  @override
  void initState() {
    super.initState();
    _pinToEnd();
  }

  void _pinToEnd() {
    // After layout, or the extent is still the old one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: Motion.of(context, Motion.normal),
        curve: Motion.decelerate,
      );
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final last = widget.trail.length - 1;

    return SizedBox(
      height: 28,
      child: ListView(
        controller: _scroll,
        scrollDirection: Axis.horizontal,
        children: [
          _Crumb(
            label: 'Nimbus',
            icon: Icons.cloud_rounded,
            current: widget.trail.isEmpty,
            onTap: () => widget.onTap(-1),
          ),
          for (var i = 0; i < widget.trail.length; i++) ...[
            Icon(
              Icons.chevron_right_rounded,
              size: 16,
              color: tokens.textTertiary,
            ),
            _Crumb(
              label: widget.trail[i].name,
              current: i == last,
              onTap: () => widget.onTap(i),
            ),
          ],
        ],
      ),
    );
  }
}

class _Crumb extends StatelessWidget {
  const _Crumb({
    required this.label,
    required this.current,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool current;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final color = current ? tokens.textPrimary : tokens.textSecondary;

    return Pressable(
      // The crumb you are on is not a destination.
      onTap: current ? null : onTap,
      scale: 0.94,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Gap.xxs),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 15, color: color),
              const SizedBox(width: Gap.xxs),
            ],
            Text(
              label,
              style: context.text.labelLarge!.copyWith(
                color: color,
                fontWeight: current ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
