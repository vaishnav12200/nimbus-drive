import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';
import 'pressable.dart';

/// Search input with built-in debouncing.
///
/// The debounce lives here rather than in each screen because forgetting it is
/// invisible in development and expensive in production: `GET /api/search`
/// runs a trigram scan, and a keystroke-per-request client turns a five-letter
/// query into five of them.
///
/// [onChanged] fires on every keystroke for local state; [onSubmitted] fires
/// after the pause and on the keyboard's search key. Query the server from the
/// latter.
class NimbusSearchField extends StatefulWidget {
  const NimbusSearchField({
    super.key,
    this.controller,
    this.hintText = 'Search files and folders',
    this.onChanged,
    this.onSubmitted,
    this.debounce = const Duration(milliseconds: 300),
    this.autofocus = false,
    this.trailing,
  });

  final TextEditingController? controller;
  final String hintText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final Duration debounce;
  final bool autofocus;

  /// A filter button, usually. Sits inside the field's right edge.
  final Widget? trailing;

  @override
  State<NimbusSearchField> createState() => _NimbusSearchFieldState();
}

class _NimbusSearchFieldState extends State<NimbusSearchField> {
  late final TextEditingController _controller =
      widget.controller ?? TextEditingController();

  /// Only dispose what we created — a caller-supplied controller usually
  /// outlives this widget.
  late final bool _ownsController = widget.controller == null;

  Timer? _timer;
  bool _hasText = false;

  @override
  void initState() {
    super.initState();
    _hasText = _controller.text.isNotEmpty;
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.removeListener(_onTextChanged);
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final text = _controller.text;
    if (_hasText != text.isNotEmpty) setState(() => _hasText = text.isNotEmpty);

    widget.onChanged?.call(text);

    _timer?.cancel();
    _timer = Timer(widget.debounce, () => widget.onSubmitted?.call(text));
  }

  void _clear() {
    _timer?.cancel();
    _controller.clear();
    // Clearing should show everything again immediately rather than after
    // another debounce — the user is not still typing.
    widget.onSubmitted?.call('');
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return TextField(
      controller: _controller,
      autofocus: widget.autofocus,
      textInputAction: TextInputAction.search,
      onSubmitted: (value) {
        _timer?.cancel();
        widget.onSubmitted?.call(value);
      },
      style: context.text.bodyLarge,
      decoration: InputDecoration(
        hintText: widget.hintText,
        prefixIcon: Icon(
          Icons.search_rounded,
          size: 20,
          color: tokens.textTertiary,
        ),
        prefixIconConstraints: const BoxConstraints(minWidth: 44),
        suffixIcon: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_hasText)
              Semantics(
                label: 'Clear search',
                button: true,
                child: Pressable(
                  onTap: _clear,
                  scale: 0.85,
                  child: Icon(
                    Icons.cancel_rounded,
                    size: 18,
                    color: tokens.textTertiary,
                  ),
                ),
              ),
            if (widget.trailing != null) ...[
              const SizedBox(width: Gap.xs),
              widget.trailing!,
            ],
            const SizedBox(width: Gap.sm),
          ],
        ),
        suffixIconConstraints: const BoxConstraints(minWidth: 0),
      ),
    );
  }
}
