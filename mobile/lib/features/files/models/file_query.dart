import 'drive_item.dart';

enum FileSort {
  name('Name', 'name'),
  size('Size', 'size'),
  modified('Last modified', 'updated_at'),
  kind('Type', 'type');

  const FileSort(this.label, this.wire);

  final String label;

  /// The API's `sort=` value, so this enum can drive the request directly once
  /// the repository talks to the server.
  final String wire;
}

enum SortOrder {
  ascending('asc'),
  descending('desc');

  const SortOrder(this.wire);

  final String wire;
}

enum FileViewMode { list, grid }

/// Everything that shapes a folder listing: what to show, in what order, how.
///
/// One immutable object rather than six fields on the controller, because
/// these are always applied together and a request built from half of them is
/// a bug that renders fine.
class FileQuery {
  const FileQuery({
    this.search = '',
    this.types = const {},
    this.favoritesOnly = false,
    this.sort = FileSort.name,
    this.order = SortOrder.ascending,
    this.view = FileViewMode.list,
  });

  final String search;

  /// Empty means no type filter. A set rather than a single value because the
  /// API accepts several and users think in "images and video", not one type.
  final Set<FileType> types;

  final bool favoritesOnly;
  final FileSort sort;
  final SortOrder order;

  /// Presentation, not a filter — kept here so one object restores the whole
  /// view when returning to a folder.
  final FileViewMode view;

  bool get hasFilters => search.isNotEmpty || types.isNotEmpty || favoritesOnly;

  /// Default direction for a freshly chosen field.
  ///
  /// Names read A→Z, but "largest first" and "newest first" are what someone
  /// actually wants when they pick size or date. Ascending everywhere is
  /// consistent and wrong.
  static SortOrder defaultOrderFor(FileSort sort) => switch (sort) {
    FileSort.name || FileSort.kind => SortOrder.ascending,
    FileSort.size || FileSort.modified => SortOrder.descending,
  };

  FileQuery copyWith({
    String? search,
    Set<FileType>? types,
    bool? favoritesOnly,
    FileSort? sort,
    SortOrder? order,
    FileViewMode? view,
  }) => FileQuery(
    search: search ?? this.search,
    types: types ?? this.types,
    favoritesOnly: favoritesOnly ?? this.favoritesOnly,
    sort: sort ?? this.sort,
    order: order ?? this.order,
    view: view ?? this.view,
  );

  FileQuery cleared() => FileQuery(sort: sort, order: order, view: view);
}
