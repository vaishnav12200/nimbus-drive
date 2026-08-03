import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/nimbus_button.dart';

/// Shared chrome for the sign-in and register screens.
///
/// Both are a back button, a heading, a form and one primary action. Sharing
/// the frame keeps them from drifting apart, which is where auth flows usually
/// start to look like two different apps.
class AuthScaffold extends StatelessWidget {
  const AuthScaffold({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
    required this.actionLabel,
    required this.onSubmit,
    required this.busy,
    this.error,
    this.footer,
  });

  final String title;
  final String subtitle;
  final List<Widget> children;
  final String actionLabel;
  final VoidCallback? onSubmit;
  final bool busy;

  /// Whole-form failure, as opposed to a per-field one.
  final String? error;

  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Gap.sm, Gap.xs, Gap.page, 0),
              child: Row(
                children: [
                  NimbusIconButton(
                    icon: Icons.arrow_back_rounded,
                    size: 40,
                    tooltip: 'Back',
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  Gap.page,
                  Gap.md,
                  Gap.page,
                  Gap.xl,
                ),
                children: [
                  Text(title, style: context.text.headlineMedium),
                  const SizedBox(height: Gap.xxs),
                  Text(
                    subtitle,
                    style: context.text.bodyMedium!.copyWith(
                      color: tokens.textSecondary,
                    ),
                  ),
                  const SizedBox(height: Gap.xl),

                  ...children,

                  if (error != null) ...[
                    const SizedBox(height: Gap.md),
                    _ErrorBanner(message: error!),
                  ],

                  const SizedBox(height: Gap.xl),
                  NimbusButton(
                    label: actionLabel,
                    size: NimbusButtonSize.large,
                    expand: true,
                    loading: busy,
                    onPressed: onSubmit,
                  ),

                  if (footer != null) ...[
                    const SizedBox(height: Gap.md),
                    Center(child: footer!),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Gap.sm),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            size: 18,
            color: AppColors.danger,
          ),
          const SizedBox(width: Gap.xs),
          Expanded(
            child: Text(
              message,
              style: context.text.bodyMedium!.copyWith(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}

/// A labelled text field that can show a server-supplied error underneath.
class AuthField extends StatefulWidget {
  const AuthField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.error,
    this.obscure = false,
    this.keyboardType,
    this.textInputAction = TextInputAction.next,
    this.autofillHints,
    this.onSubmitted,
    this.autofocus = false,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;

  /// Message from `details.fields`, shown beneath the input.
  final String? error;

  final bool obscure;
  final TextInputType? keyboardType;
  final TextInputAction textInputAction;
  final Iterable<String>? autofillHints;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;

  @override
  State<AuthField> createState() => _AuthFieldState();
}

class _AuthFieldState extends State<AuthField> {
  late bool _hidden = widget.obscure;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.label,
            style: context.text.labelLarge!.copyWith(
              color: tokens.textSecondary,
            ),
          ),
          const SizedBox(height: Gap.xs),
          TextField(
            controller: widget.controller,
            obscureText: _hidden,
            autofocus: widget.autofocus,
            keyboardType: widget.keyboardType,
            textInputAction: widget.textInputAction,
            autofillHints: widget.autofillHints,
            onSubmitted: widget.onSubmitted,
            style: context.text.bodyLarge,
            decoration: InputDecoration(
              hintText: widget.hint,
              // The border turns red without moving anything: the error text
              // sits outside the field, so showing it cannot shift the layout
              // under the user's thumb.
              enabledBorder: widget.error == null
                  ? null
                  : OutlineInputBorder(
                      borderRadius: BorderRadius.circular(Radii.md),
                      borderSide: const BorderSide(
                        color: AppColors.danger,
                        width: 1.5,
                      ),
                    ),
              suffixIcon: widget.obscure
                  ? IconButton(
                      icon: Icon(
                        _hidden
                            ? Icons.visibility_rounded
                            : Icons.visibility_off_rounded,
                        size: 20,
                        color: tokens.textTertiary,
                      ),
                      tooltip: _hidden ? 'Show password' : 'Hide password',
                      onPressed: () => setState(() => _hidden = !_hidden),
                    )
                  : null,
            ),
          ),
          if (widget.error != null) ...[
            const SizedBox(height: Gap.xxs),
            Text(
              widget.error!,
              style: context.text.bodySmall!.copyWith(color: AppColors.danger),
            ),
          ],
        ],
      ),
    );
  }
}
