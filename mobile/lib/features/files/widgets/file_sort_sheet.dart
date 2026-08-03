import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_dimens.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/nimbus_feedback.dart';
import '../../../core/widgets/nimbus_list_row.dart';
import '../models/file_query.dart';

/// Sort picker.
///
/// Shows the direction on the selected field rather than as a separate
/// asc/desc control, because "Size ↓" is one decision presented as one thing.
/// Tapping the selected field again flips it.
Future<void> showFileSortSheet(
  BuildContext context, {
  required FileQuery query,
  required ValueChanged<FileSort> onSelected,
}) {
  return NimbusFeedback.sheet<void>(
    context,
    builder: (context) => Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const NimbusSheetHeader(title: 'Sort by'),
        for (final sort in FileSort.values)
          Builder(
            builder: (context) {
              final selected = sort == query.sort;
              final ascending = query.order == SortOrder.ascending;

              return NimbusListRow(
                title: sort.label,
                subtitle: selected
                    ? (ascending ? _ascLabel(sort) : _descLabel(sort))
                    : null,
                icon: _iconFor(sort),
                iconColor: selected
                    ? AppColors.primary
                    : context.tokens.textSecondary,
                selected: selected,
                trailing: selected
                    ? Icon(
                        ascending
                            ? Icons.arrow_upward_rounded
                            : Icons.arrow_downward_rounded,
                        size: 18,
                        color: AppColors.primary,
                      )
                    : null,
                onTap: () {
                  onSelected(sort);
                  // Stays open only when flipping direction would be the next
                  // thing you want; picking a new field is a finished
                  // decision.
                  if (!selected) Navigator.of(context).pop();
                },
              );
            },
          ),
        const SizedBox(height: Gap.xs),
      ],
    ),
  );
}

IconData _iconFor(FileSort sort) => switch (sort) {
  FileSort.name => Icons.sort_by_alpha_rounded,
  FileSort.size => Icons.data_usage_rounded,
  FileSort.modified => Icons.schedule_rounded,
  FileSort.kind => Icons.category_rounded,
};

String _ascLabel(FileSort sort) => switch (sort) {
  FileSort.name => 'A to Z',
  FileSort.size => 'Smallest first',
  FileSort.modified => 'Oldest first',
  FileSort.kind => 'Images to other',
};

String _descLabel(FileSort sort) => switch (sort) {
  FileSort.name => 'Z to A',
  FileSort.size => 'Largest first',
  FileSort.modified => 'Newest first',
  FileSort.kind => 'Other to images',
};
