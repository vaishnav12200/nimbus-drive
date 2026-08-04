import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_dimens.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/nimbus_button.dart';
import '../../core/widgets/nimbus_chip.dart';
import '../../core/widgets/nimbus_empty_state.dart';
import '../../core/widgets/nimbus_feedback.dart';
import '../../core/widgets/nimbus_list_row.dart';
import '../../core/widgets/nimbus_search_field.dart';
import '../../core/widgets/nimbus_skeleton.dart';
import '../../core/widgets/nimbus_tile.dart';
import '../encryption/encryption_controller.dart';
import '../telegram/data/bot_token_store.dart';
import 'data/download_service.dart';
import 'file_preview_screen.dart';
import 'files_controller.dart';
import 'models/drive_item.dart';
import 'models/file_query.dart';
import 'widgets/file_actions_sheet.dart';
import 'widgets/file_breadcrumbs.dart';
import 'widgets/file_sort_sheet.dart';

/// Browse folders and files.
///
/// Tap a folder to descend, long-press anything for its actions. The screen
/// reads from [FilesController] and never from a repository directly, so the
/// switch from the in-memory fake to the API changes nothing here.
typedef OpenFile = void Function(DriveFile file);

class FilesScreen extends StatelessWidget {
  const FilesScreen({
    super.key,
    required this.controller,
    required this.onOpenUpload,
    required this.downloads,
    required this.encryption,
    required this.botTokens,
  });

  final FilesController controller;
  final DownloadService downloads;
  final EncryptionController encryption;

  /// Needed for the direct route: a small file comes straight from Telegram,
  /// which requires the token this device holds.
  final BotTokenStore botTokens;

  /// Switches to the Upload tab. The empty state offers it, so it has to lead
  /// somewhere real rather than explain that uploading exists elsewhere.
  final VoidCallback onOpenUpload;

  Future<void> _open(BuildContext context, DriveFile file) async {
    final token = await botTokens.read();
    if (!context.mounted) return;

    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FilePreviewScreen(
          file: file,
          downloads: downloads,
          encryption: encryption,
          botToken: token,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        // Intercepts the system back gesture to climb the folder tree before
        // letting it pop the route — otherwise back from three folders deep
        // leaves the app instead of going up one.
        return PopScope(
          canPop: controller.isRoot,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) controller.goUp();
          },
          child: SafeArea(
            bottom: false,
            child: Column(
              children: [
                _Header(controller: controller),
                Expanded(
                  child: _Body(
                    controller: controller,
                    onOpenUpload: onOpenUpload,
                    onOpen: (file) => _open(context, file),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final FilesController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final query = controller.query;
    final grid = query.view == FileViewMode.grid;

    return Padding(
      padding: const EdgeInsets.fromLTRB(Gap.page, Gap.xs, Gap.page, Gap.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (!controller.isRoot) ...[
                NimbusIconButton(
                  icon: Icons.arrow_back_rounded,
                  size: 40,
                  tooltip: 'Up one folder',
                  onPressed: controller.goUp,
                ),
                const SizedBox(width: Gap.xs),
              ],
              Expanded(
                child: Text(
                  controller.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.text.headlineMedium,
                ),
              ),
              NimbusIconButton(
                icon: grid ? Icons.view_list_rounded : Icons.grid_view_rounded,
                size: 40,
                tooltip: grid ? 'List view' : 'Grid view',
                onPressed: () => controller.setView(
                  grid ? FileViewMode.list : FileViewMode.grid,
                ),
              ),
              const SizedBox(width: Gap.xs),
              NimbusIconButton(
                icon: Icons.swap_vert_rounded,
                size: 40,
                tooltip: 'Sort',
                onPressed: () => showFileSortSheet(
                  context,
                  query: query,
                  onSelected: controller.setSort,
                ),
              ),
              const SizedBox(width: Gap.xs),
              NimbusIconButton(
                icon: Icons.create_new_folder_outlined,
                size: 40,
                tooltip: 'New folder',
                onPressed: () => _promptNewFolder(context, controller),
              ),
            ],
          ),
          const SizedBox(height: Gap.sm),

          FileBreadcrumbs(
            trail: controller.breadcrumbs,
            onTap: controller.goToCrumb,
          ),
          const SizedBox(height: Gap.sm),

          NimbusSearchField(
            // Rebuilds the field when the folder changes so its text clears
            // with the query rather than lingering over new contents.
            key: ValueKey(controller.currentFolderId),
            onSubmitted: controller.search,
          ),
          const SizedBox(height: Gap.sm),

          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            child: Row(
              children: [
                NimbusChip(
                  label: 'Favourites',
                  icon: Icons.star_rounded,
                  selected: query.favoritesOnly,
                  accent: AppColors.warning,
                  onTap: controller.toggleFavoritesOnly,
                ),
                const SizedBox(width: Gap.xs),
                Container(width: 1, height: 20, color: tokens.outline),
                const SizedBox(width: Gap.xs),
                for (final type in FileType.values) ...[
                  NimbusChip(
                    label: type.label,
                    selected: query.types.contains(type),
                    accent: tokens.accentForType(type.wire),
                    onTap: () => controller.toggleType(type),
                  ),
                  const SizedBox(width: Gap.xs),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Asks for a name, then creates the folder in whichever folder is open.
Future<void> _promptNewFolder(
  BuildContext context,
  FilesController controller,
) async {
  final field = TextEditingController();

  final name = await NimbusFeedback.sheet<String>(
    context,
    builder: (sheetContext) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NimbusSheetHeader(title: 'New folder'),
        TextField(
          controller: field,
          autofocus: true,
          textInputAction: TextInputAction.done,
          onSubmitted: (v) => Navigator.of(sheetContext).pop(v.trim()),
          decoration: const InputDecoration(hintText: 'Folder name'),
        ),
        const SizedBox(height: Gap.md),
        NimbusButton(
          label: 'Create',
          expand: true,
          onPressed: () => Navigator.of(sheetContext).pop(field.text.trim()),
        ),
      ],
    ),
  );

  field.dispose();
  if (name == null || name.isEmpty || !context.mounted) return;

  try {
    await controller.createFolder(name);
    if (context.mounted) NimbusFeedback.success(context, 'Created "$name"');
  } catch (e) {
    // Sibling names must be unique, and the server says so precisely.
    if (context.mounted) NimbusFeedback.error(context, '$e');
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.controller,
    required this.onOpenUpload,
    required this.onOpen,
  });

  final FilesController controller;
  final VoidCallback onOpenUpload;
  final OpenFile onOpen;

  @override
  Widget build(BuildContext context) {
    if (controller.loading) return const _LoadingList();

    if (controller.error != null) {
      return NimbusEmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Could not load this folder',
        message: controller.error,
        actionLabel: 'Try again',
        accent: AppColors.danger,
        onAction: controller.refresh,
      );
    }

    if (controller.items.isEmpty) {
      // Two different empties. Offering "Upload" to someone who filtered to
      // nothing is answering a question they did not ask.
      return controller.isFilteredEmpty
          ? NimbusEmptyState(
              icon: Icons.filter_alt_off_rounded,
              title: 'Nothing matches',
              message: 'No files here match the current search and filters.',
              actionLabel: 'Clear filters',
              onAction: controller.clearFilters,
            )
          : NimbusEmptyState(
              icon: Icons.folder_open_rounded,
              title: 'This folder is empty',
              message: 'Upload a file or create a folder to get started.',
              actionLabel: 'Upload',
              accent: AppColors.primary,
              onAction: onOpenUpload,
            );
    }

    return RefreshIndicator(
      onRefresh: controller.refresh,
      backgroundColor: context.tokens.raised,
      color: AppColors.primary,
      child: controller.query.view == FileViewMode.grid
          ? _Grid(controller: controller, onOpen: onOpen)
          : _List(controller: controller, onOpen: onOpen),
    );
  }
}

class _List extends StatelessWidget {
  const _List({required this.controller, required this.onOpen});

  final FilesController controller;
  final OpenFile onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(Gap.sm, 0, Gap.sm, 104),
      itemCount: controller.items.length,
      itemBuilder: (context, i) {
        final item = controller.items[i];

        return NimbusListRow(
          title: item.name,
          subtitle: _subtitleFor(item),
          icon: switch (item) {
            DriveFolder() => Icons.folder_rounded,
            DriveFile(:final type) => type.icon,
          },
          iconColor: switch (item) {
            DriveFolder() => AppColors.primary,
            DriveFile(:final type) => tokens.accentForType(type.wire),
          },
          trailing: _Badges(item: item),
          onTap: () => switch (item) {
            DriveFolder() => controller.open(item),
            // Tap opens the file now that there is somewhere to open it;
            // long-press remains the way to reach everything else.
            DriveFile() => onOpen(item),
          },
          onLongPress: () => showFileActionsSheet(
            context,
            item: item,
            controller: controller,
            onOpen: item is DriveFile ? () => onOpen(item) : null,
          ),
        );
      },
    );
  }
}

class _Grid extends StatelessWidget {
  const _Grid({required this.controller, required this.onOpen});

  final FilesController controller;
  final OpenFile onOpen;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(Gap.page, 0, Gap.page, 104),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        // Max extent rather than a fixed count, so a tablet or a large phone
        // gains a column instead of stretching two of them.
        maxCrossAxisExtent: 190,
        mainAxisSpacing: Gap.xs,
        crossAxisSpacing: Gap.xs,
        childAspectRatio: 0.86,
      ),
      itemCount: controller.items.length,
      itemBuilder: (context, i) {
        final item = controller.items[i];

        return NimbusTile(
          title: item.name,
          subtitle: _subtitleFor(item),
          icon: switch (item) {
            DriveFolder() => Icons.folder_rounded,
            DriveFile(:final type) => type.icon,
          },
          accent: switch (item) {
            DriveFolder() => AppColors.primary,
            DriveFile(:final type) => tokens.accentForType(type.wire),
          },
          badge: switch (item) {
            DriveFile(isEncrypted: true) => Icons.lock_rounded,
            DriveFile(isShared: true) => Icons.link_rounded,
            _ => item.isFavorite ? Icons.star_rounded : null,
          },
          onTap: () => switch (item) {
            DriveFolder() => controller.open(item),
            // Tap opens the file now that there is somewhere to open it;
            // long-press remains the way to reach everything else.
            DriveFile() => onOpen(item),
          },
          onLongPress: () => showFileActionsSheet(
            context,
            item: item,
            controller: controller,
            onOpen: item is DriveFile ? () => onOpen(item) : null,
          ),
        );
      },
    );
  }
}

String _subtitleFor(DriveItem item) => switch (item) {
  // A folder's aggregate size is not something the API reports, so it is shown
  // only when a source actually supplies it.
  DriveFolder(:final itemCount, :final size) =>
    size > 0
        ? '$itemCount items · ${formatBytes(size)}'
        : (itemCount == 1 ? '1 item' : '$itemCount items'),
  DriveFile(:final size, :final updatedAt) =>
    '${formatBytes(size)} · ${formatWhen(updatedAt)}',
};

class _Badges extends StatelessWidget {
  const _Badges({required this.item});

  final DriveItem item;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    final icons = <(IconData, Color)>[
      if (item.isFavorite) (Icons.star_rounded, AppColors.warning),
      if (item is DriveFile && (item as DriveFile).isEncrypted)
        (Icons.lock_rounded, tokens.textTertiary),
      if (item is DriveFile && (item as DriveFile).isShared)
        (Icons.link_rounded, tokens.textTertiary),
      if (item is DriveFolder)
        (Icons.chevron_right_rounded, tokens.textTertiary),
    ];

    if (icons.isEmpty) return const SizedBox.shrink();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (icon, color) in icons)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Icon(icon, size: 16, color: color),
          ),
      ],
    );
  }
}

class _LoadingList extends StatelessWidget {
  const _LoadingList();

  @override
  Widget build(BuildContext context) {
    // Widths vary so the placeholder reads as a list of different files rather
    // than a striped pattern.
    const widths = [190.0, 130.0, 220.0, 160.0, 200.0, 120.0, 175.0];

    return NimbusSkeletonGroup(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(Gap.sm, 0, Gap.sm, 104),
        physics: const NeverScrollableScrollPhysics(),
        children: [
          for (final width in widths) NimbusRowSkeleton(titleWidth: width),
        ],
      ),
    );
  }
}
