import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';
import 'nimbus_button.dart';

/// Toasts, sheets and confirmations.
///
/// These exist as helpers rather than as widgets each screen assembles because
/// feedback is where inconsistency shows up worst: three screens inventing
/// three error styles is what makes an app feel unfinished, and the backend
/// hands every route the same failure shape to report.
abstract final class NimbusFeedback {
  /// Transient message. Use for outcomes the user can ignore.
  static void toast(
    BuildContext context,
    String message, {
    IconData? icon,
    Color? accent,
    SnackBarAction? action,
  }) {
    final tokens = context.tokens;
    final tint = accent ?? tokens.textPrimary;

    ScaffoldMessenger.of(context)
      // Replace rather than queue. Stacked toasts mean the user reads the
      // third one a full second after the action that caused the first.
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: tint),
                const SizedBox(width: Gap.xs),
              ],
              Expanded(child: Text(message)),
            ],
          ),
          action: action,
          duration: const Duration(seconds: 4),
        ),
      );
  }

  /// Failure toast. Takes the message the server already wrote.
  ///
  /// `docs/API.md` is explicit that clients switch on `error.code` and show
  /// `error.message` — the messages are written for humans and will change, so
  /// there is nothing to gain from paraphrasing them here.
  static void error(BuildContext context, String message) => toast(
    context,
    message,
    icon: Icons.error_outline_rounded,
    accent: AppColors.danger,
  );

  static void success(BuildContext context, String message) => toast(
    context,
    message,
    icon: Icons.check_circle_outline_rounded,
    accent: AppColors.success,
  );

  /// Themed modal bottom sheet. Returns whatever the sheet pops with.
  static Future<T?> sheet<T>(
    BuildContext context, {
    required WidgetBuilder builder,
    bool isScrollControlled = true,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      isScrollControlled: isScrollControlled,
      // Lets a sheet grow past half height without the caller configuring it,
      // which is what a file's action list or a filter form needs.
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.9,
      ),
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          left: Gap.page,
          right: Gap.page,
          top: Gap.xs,
          // Clears the keyboard when the sheet contains a field.
          bottom: MediaQuery.viewInsetsOf(context).bottom + Gap.xl,
        ),
        child: builder(context),
      ),
    );
  }

  /// Yes/no for a destructive action.
  ///
  /// Returns true only on explicit confirmation — dismissing by tapping away
  /// yields null, which is falsy, so an accidental dismissal can never delete
  /// anything.
  static Future<bool> confirm(
    BuildContext context, {
    required String title,
    required String message,
    String confirmLabel = 'Delete',
    String cancelLabel = 'Cancel',
    bool destructive = true,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actionsPadding: const EdgeInsets.fromLTRB(Gap.md, 0, Gap.md, Gap.md),
        actions: [
          NimbusButton(
            label: cancelLabel,
            variant: NimbusButtonVariant.ghost,
            size: NimbusButtonSize.small,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          NimbusButton(
            label: confirmLabel,
            variant: destructive
                ? NimbusButtonVariant.danger
                : NimbusButtonVariant.primary,
            size: NimbusButtonSize.small,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

/// Drag handle plus title, for the top of a sheet.
class NimbusSheetHeader extends StatelessWidget {
  const NimbusSheetHeader({super.key, required this.title, this.action});

  final String title;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Gap.md),
      child: Row(
        children: [
          Expanded(child: Text(title, style: context.text.titleLarge)),
          ?action,
        ],
      ),
    );
  }
}
