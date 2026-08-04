import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/nimbus_button.dart';
import '../../../core/widgets/nimbus_feedback.dart';
import '../../../core/widgets/nimbus_list_row.dart';
import '../files_controller.dart';
import '../models/drive_item.dart';

/// Long-press menu for a file or folder.
///
/// The sheet closes before any async work runs. A sheet that lingers behind a
/// spinner leaves the user unsure whether the tap registered, and it makes the
/// `BuildContext` outlive its route.
Future<void> showFileActionsSheet(
  BuildContext context, {
  required DriveItem item,
  required FilesController controller,
  VoidCallback? onOpen,
}) {
  return NimbusFeedback.sheet<void>(
    context,
    builder: (sheetContext) {
      final tokens = sheetContext.tokens;
      final isFile = item is DriveFile;

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Summary(item: item),
          const SizedBox(height: Gap.xs),
          Divider(color: tokens.outline),
          const SizedBox(height: Gap.xs),

          if (isFile && onOpen != null)
            NimbusListRow(
              title: 'Open',
              subtitle: item.isEncrypted
                  ? 'Downloads and decrypts on this device'
                  : null,
              icon: Icons.open_in_new_rounded,
              iconColor: AppColors.primary,
              onTap: () {
                Navigator.of(sheetContext).pop();
                onOpen();
              },
            ),

          NimbusListRow(
            title: 'Rename',
            icon: Icons.drive_file_rename_outline_rounded,
            iconColor: tokens.textSecondary,
            onTap: () {
              Navigator.of(sheetContext).pop();
              _promptRename(context, item: item, controller: controller);
            },
          ),

          NimbusListRow(
            title: item.isFavorite
                ? 'Remove from favourites'
                : 'Add to favourites',
            icon: item.isFavorite
                ? Icons.star_rounded
                : Icons.star_outline_rounded,
            iconColor: item.isFavorite
                ? AppColors.warning
                : tokens.textSecondary,
            onTap: () {
              Navigator.of(sheetContext).pop();
              controller.toggleFavorite(item);
            },
          ),

          if (isFile)
            NimbusListRow(
              title: 'Copy share link',
              subtitle: item.isEncrypted
                  ? 'Unavailable — the file is encrypted'
                  : null,
              icon: Icons.link_rounded,
              iconColor: item.isEncrypted
                  ? tokens.textTertiary
                  : tokens.textSecondary,
              // Disabled rather than hidden: a missing row reads as a bug,
              // and the reason is worth showing.
              onTap: item.isEncrypted
                  ? null
                  : () {
                      Navigator.of(sheetContext).pop();
                      _share(context, file: item, controller: controller);
                    },
            ),

          NimbusListRow(
            title: 'Delete',
            subtitle: item is DriveFolder
                ? 'Moves everything inside to the trash'
                : 'Moves to the trash',
            icon: Icons.delete_outline_rounded,
            iconColor: AppColors.danger,
            onTap: () {
              Navigator.of(sheetContext).pop();
              _confirmDelete(context, item: item, controller: controller);
            },
          ),

          const SizedBox(height: Gap.xs),
        ],
      );
    },
  );
}

class _Summary extends StatelessWidget {
  const _Summary({required this.item});

  final DriveItem item;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    final (IconData icon, Color color, String detail) = switch (item) {
      DriveFolder(:final itemCount, :final size) => (
        Icons.folder_rounded,
        item.isFavorite ? AppColors.primary : tokens.textSecondary,
        '$itemCount items · ${formatBytes(size)}',
      ),
      DriveFile(:final type, :final size, :final isEncrypted) => (
        type.icon,
        tokens.accentForType(type.wire),
        '${formatBytes(size)}${isEncrypted ? ' · encrypted' : ''}',
      ),
    };

    return Row(
      children: [
        Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(Radii.sm),
          ),
          child: Icon(icon, size: 24, color: color),
        ),
        const SizedBox(width: Gap.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.text.titleMedium,
              ),
              const SizedBox(height: 2),
              Text(
                '$detail · ${formatWhen(item.updatedAt)}',
                style: context.text.bodySmall!.copyWith(
                  color: tokens.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Future<void> _promptRename(
  BuildContext context, {
  required DriveItem item,
  required FilesController controller,
}) async {
  // Files open with only the stem selected, so replacing the name cannot
  // silently drop the extension.
  final controllerText = TextEditingController(text: item.name);
  if (item is DriveFile && item.extension.isNotEmpty) {
    controllerText.selection = TextSelection(
      baseOffset: 0,
      extentOffset: item.baseName.length,
    );
  }

  final name = await NimbusFeedback.sheet<String>(
    context,
    builder: (sheetContext) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NimbusSheetHeader(title: 'Rename'),
        TextField(
          controller: controllerText,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.of(sheetContext).pop(v.trim()),
          decoration: const InputDecoration(hintText: 'Name'),
        ),
        const SizedBox(height: Gap.md),
        NimbusButton(
          label: 'Rename',
          expand: true,
          onPressed: () =>
              Navigator.of(sheetContext).pop(controllerText.text.trim()),
        ),
      ],
    ),
  );

  controllerText.dispose();
  if (name == null || name.isEmpty || name == item.name) return;
  if (!context.mounted) return;

  try {
    await controller.rename(item, name);
    if (context.mounted) NimbusFeedback.success(context, 'Renamed to $name');
  } catch (e) {
    if (context.mounted) NimbusFeedback.error(context, '$e');
  }
}

Future<void> _share(
  BuildContext context, {
  required DriveFile file,
  required FilesController controller,
}) async {
  try {
    final url = await controller.share(file);
    await Clipboard.setData(ClipboardData(text: url));
    if (context.mounted) NimbusFeedback.success(context, 'Link copied');
  } catch (e) {
    if (context.mounted) NimbusFeedback.error(context, '$e');
  }
}

Future<void> _confirmDelete(
  BuildContext context, {
  required DriveItem item,
  required FilesController controller,
}) async {
  final confirmed = await NimbusFeedback.confirm(
    context,
    title: 'Delete "${item.name}"?',
    message: item is DriveFolder
        ? 'The folder and everything in it move to the trash. Files can be '
              'restored for 30 days.'
        : 'It moves to the trash and can be restored for 30 days.',
  );
  if (!confirmed || !context.mounted) return;

  try {
    await controller.delete(item);
    if (context.mounted) NimbusFeedback.toast(context, 'Moved to trash');
  } catch (e) {
    if (context.mounted) NimbusFeedback.error(context, '$e');
  }
}
