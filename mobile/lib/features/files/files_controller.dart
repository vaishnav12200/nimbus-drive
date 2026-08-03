import 'package:flutter/foundation.dart';

import 'data/file_repository.dart';
import 'models/drive_item.dart';
import 'models/file_query.dart';

/// State for the Files screen.
///
/// A [ChangeNotifier] rather than a state-management package: nothing here
/// needs more, and `TODO.md` has not settled on riverpod or bloc. The screen
/// talks to this and the repository interface only, so adopting one later
/// replaces this file without touching the widgets.
class FilesController extends ChangeNotifier {
  FilesController(this._repository) {
    _load();
  }

  final FileRepository _repository;

  /// Folder ids from the root down to where the user is. Empty means root.
  final List<String> _path = [];

  FileQuery _query = const FileQuery();
  List<DriveItem> _items = const [];
  List<DriveFolder> _breadcrumbs = const [];
  bool _loading = true;
  String? _error;

  /// Guards against out-of-order responses.
  ///
  /// Typing in the search box or tapping through folders quickly starts
  /// several loads; without this the slowest one wins and the list shows
  /// results for a query the user has already moved past.
  int _generation = 0;

  FileQuery get query => _query;
  List<DriveItem> get items => _items;
  List<DriveFolder> get breadcrumbs => _breadcrumbs;
  bool get loading => _loading;
  String? get error => _error;
  bool get isRoot => _path.isEmpty;
  String? get currentFolderId => _path.isEmpty ? null : _path.last;

  String get title => _breadcrumbs.isEmpty ? 'Files' : _breadcrumbs.last.name;

  /// True when the folder really is empty, as opposed to filtered to nothing.
  /// The two need different empty states — one invites an upload, the other
  /// offers to clear the filters.
  bool get isFilteredEmpty => _items.isEmpty && _query.hasFilters;

  Future<void> _load() async {
    final generation = ++_generation;
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final listing = await _repository.list(
        folderId: currentFolderId,
        query: _query,
      );
      if (generation != _generation) return;

      _items = listing.items;
      _breadcrumbs = listing.breadcrumbs;
    } catch (e) {
      if (generation != _generation) return;
      _error = '$e';
    } finally {
      if (generation == _generation) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> refresh() => _load();

  // --- Navigation -----------------------------------------------------------

  void open(DriveFolder folder) {
    _path.add(folder.id);
    // Filters are per-folder. Carrying a search term into a folder the user
    // just opened hides everything in it and looks like an empty folder.
    _query = _query.cleared();
    _load();
  }

  /// Returns false when already at the root, so the caller can let the system
  /// back gesture pop the route instead.
  bool goUp() {
    if (_path.isEmpty) return false;
    _path.removeLast();
    _query = _query.cleared();
    _load();
    return true;
  }

  void goToCrumb(int index) {
    // index -1 is the root crumb.
    _path.removeRange(index + 1, _path.length);
    _query = _query.cleared();
    _load();
  }

  // --- Query ----------------------------------------------------------------

  void search(String value) {
    if (_query.search == value) return;
    _query = _query.copyWith(search: value);
    _load();
  }

  /// Jumps to the drive root showing only [type], or everything when null.
  ///
  /// Used when another screen asks a question about a category — the answer is
  /// the whole drive filtered, not whichever folder was last open.
  void showOnly(FileType? type) {
    _path.clear();
    _query = _query.cleared().copyWith(types: type == null ? {} : {type});
    _load();
  }

  void toggleType(FileType type) {
    final types = Set<FileType>.from(_query.types);
    if (!types.remove(type)) types.add(type);
    _query = _query.copyWith(types: types);
    _load();
  }

  void setSort(FileSort sort) {
    // Re-picking the current field flips direction, which is what a second tap
    // on the same option is universally taken to mean.
    _query = _query.sort == sort
        ? _query.copyWith(
            order: _query.order == SortOrder.ascending
                ? SortOrder.descending
                : SortOrder.ascending,
          )
        : _query.copyWith(sort: sort, order: FileQuery.defaultOrderFor(sort));
    _load();
  }

  void toggleFavoritesOnly() {
    _query = _query.copyWith(favoritesOnly: !_query.favoritesOnly);
    _load();
  }

  void clearFilters() {
    _query = _query.cleared();
    _load();
  }

  /// View mode changes nothing about the data, so it does not refetch.
  void setView(FileViewMode view) {
    if (_query.view == view) return;
    _query = _query.copyWith(view: view);
    notifyListeners();
  }

  // --- Mutations ------------------------------------------------------------
  //
  // Each reloads rather than patching the local list. Against an in-memory
  // fake that is free; against the API it is what keeps the list agreeing with
  // the server after a rename that the server may have adjusted.

  Future<void> rename(DriveItem item, String name) async {
    await _repository.rename(item.id, name);
    await _load();
  }

  Future<void> toggleFavorite(DriveItem item) async {
    await _repository.setFavorite(item.id, !item.isFavorite);
    await _load();
  }

  Future<void> delete(DriveItem item) async {
    await _repository.delete(item.id);
    await _load();
  }

  Future<String> share(DriveFile file) => _repository.createShareLink(file.id);

  Future<void> createFolder(String name) async {
    await _repository.createFolder(parentId: currentFolderId, name: name);
    await _load();
  }
}
