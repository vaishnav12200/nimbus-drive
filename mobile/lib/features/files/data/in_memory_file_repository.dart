import '../models/drive_item.dart';
import '../models/file_query.dart';
import 'file_repository.dart';

/// A [FileRepository] backed by a seeded map, for building and reviewing the
/// UI before the API client exists.
///
/// It reproduces the behaviours the screen has to handle rather than just
/// returning rows: latency so the loading state is real, sibling-name
/// uniqueness, the encrypted-share refusal. A fake that always succeeds
/// instantly lets error and loading paths ship untested.
class InMemoryFileRepository implements FileRepository {
  InMemoryFileRepository({this.latency = const Duration(milliseconds: 450)}) {
    _seed();
  }

  /// Artificial delay on every call. Without it the skeletons never appear in
  /// development and nobody notices they are broken.
  final Duration latency;

  final Map<String, DriveFolder> _folders = {};
  final Map<String, DriveFile> _files = {};

  @override
  Future<FolderListing> list({
    String? folderId,
    required FileQuery query,
  }) async {
    await Future<void>.delayed(latency);

    final folders = _folders.values.where((f) => f.parentId == folderId);
    final files = _files.values.where((f) => f.folderId == folderId);

    var items = <DriveItem>[...folders, ...files];
    items = items.where((item) => _matches(item, query)).toList();
    items.sort((a, b) => _compare(a, b, query));

    return FolderListing(
      items: items,
      folder: folderId == null ? null : _folders[folderId],
      breadcrumbs: _breadcrumbs(folderId),
    );
  }

  @override
  Future<DriveSummary> summary({int recentLimit = 5}) async {
    await Future<void>.delayed(latency);

    final bytesByType = <FileType, int>{};
    for (final file in _files.values) {
      bytesByType.update(
        file.type,
        (v) => v + file.size,
        ifAbsent: () => file.size,
      );
    }

    final recent = _files.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

    return DriveSummary(
      storageUsed: _files.values.fold(0, (sum, f) => sum + f.size),
      storageQuota: kStorageQuota,
      bytesByType: bytesByType,
      recent: recent.take(recentLimit).toList(),
      encryptedCount: _files.values.where((f) => f.isEncrypted).length,
    );
  }

  bool _matches(DriveItem item, FileQuery query) {
    if (query.search.isNotEmpty &&
        !item.name.toLowerCase().contains(query.search.toLowerCase())) {
      return false;
    }
    if (query.favoritesOnly && !item.isFavorite) return false;

    // A type filter is about files. Folders stay visible so the user can still
    // navigate — hiding the path to a matching file is worse than showing a
    // folder that does not match.
    if (query.types.isNotEmpty && item is DriveFile) {
      if (!query.types.contains(item.type)) return false;
    }
    return true;
  }

  int _compare(DriveItem a, DriveItem b, FileQuery query) {
    // Folders always lead, in both directions. Reversing the sort should not
    // bury the navigation at the bottom of the list.
    if (a.isFolder != b.isFolder) return a.isFolder ? -1 : 1;

    final sign = query.order == SortOrder.ascending ? 1 : -1;

    return sign *
        switch (query.sort) {
          FileSort.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          FileSort.modified => a.updatedAt.compareTo(b.updatedAt),
          FileSort.size => _sizeOf(a).compareTo(_sizeOf(b)),
          FileSort.kind => _kindOf(a).compareTo(_kindOf(b)),
        };
  }

  int _sizeOf(DriveItem item) => switch (item) {
    DriveFolder(:final size) => size,
    DriveFile(:final size) => size,
  };

  String _kindOf(DriveItem item) => switch (item) {
    DriveFolder() => '',
    DriveFile(:final type) => type.wire,
  };

  List<DriveFolder> _breadcrumbs(String? folderId) {
    final trail = <DriveFolder>[];
    var current = folderId == null ? null : _folders[folderId];
    while (current != null) {
      trail.insert(0, current);
      current = current.parentId == null ? null : _folders[current.parentId];
    }
    return trail;
  }

  @override
  Future<void> rename(String id, String name) async {
    await Future<void>.delayed(latency);

    final parent = _parentOf(id);
    final clash = [
      ..._folders.values.where((f) => f.parentId == parent),
      ..._files.values.where((f) => f.folderId == parent),
    ].any((i) => i.id != id && i.name.toLowerCase() == name.toLowerCase());

    if (clash) {
      throw DuplicateName('Something here is already called "$name"');
    }

    if (_folders.containsKey(id)) {
      _folders[id] = _folders[id]!.copyWith(name: name);
    } else if (_files.containsKey(id)) {
      _files[id] = _files[id]!.copyWith(name: name);
    }
  }

  String? _parentOf(String id) =>
      _folders[id]?.parentId ?? _files[id]?.folderId;

  @override
  Future<void> setFavorite(String id, bool value) async {
    await Future<void>.delayed(latency);
    if (_folders.containsKey(id)) {
      _folders[id] = _folders[id]!.copyWith(isFavorite: value);
    } else if (_files.containsKey(id)) {
      _files[id] = _files[id]!.copyWith(isFavorite: value);
    }
  }

  @override
  Future<void> delete(String id) async {
    await Future<void>.delayed(latency);
    _files.remove(id);
    if (_folders.remove(id) != null) {
      // Cascade, matching `DELETE /folders/{id}?cascade=true`. The screen only
      // reaches this after confirming, so the subtree goes with it.
      _files.removeWhere((_, f) => f.folderId == id);
      _folders.removeWhere((_, f) => f.parentId == id);
    }
  }

  @override
  Future<String> createShareLink(String fileId) async {
    await Future<void>.delayed(latency);

    final file = _files[fileId];
    if (file != null && file.isEncrypted) {
      throw const ShareNotAllowed(
        'Encrypted files cannot be shared — the recipient has no key',
      );
    }
    return 'https://nimbus.example/s/${fileId.substring(0, 8)}';
  }

  @override
  Future<DriveFolder> createFolder({
    String? parentId,
    required String name,
  }) async {
    await Future<void>.delayed(latency);

    final clash = _folders.values.any(
      (f) =>
          f.parentId == parentId && f.name.toLowerCase() == name.toLowerCase(),
    );
    if (clash) throw DuplicateName('A folder here is already called "$name"');

    final folder = DriveFolder(
      id: 'fol-${DateTime.now().microsecondsSinceEpoch}',
      name: name,
      updatedAt: DateTime.now(),
      parentId: parentId,
    );
    _folders[folder.id] = folder;
    return folder;
  }

  // --- Seed -----------------------------------------------------------------

  void _seed() {
    final now = DateTime.now();
    DateTime ago(int days, [int hours = 0]) =>
        now.subtract(Duration(days: days, hours: hours));

    void folder(
      String id,
      String name, {
      String? parent,
      int items = 0,
      int size = 0,
      bool fav = false,
      int days = 2,
    }) {
      _folders[id] = DriveFolder(
        id: id,
        name: name,
        updatedAt: ago(days),
        parentId: parent,
        itemCount: items,
        size: size,
        isFavorite: fav,
      );
    }

    void file(
      String id,
      String name,
      FileType type,
      int size, {
      String? parent,
      int days = 1,
      int hours = 0,
      bool fav = false,
      bool enc = false,
      bool shared = false,
    }) {
      _files[id] = DriveFile(
        id: id,
        name: name,
        updatedAt: ago(days, hours),
        size: size,
        type: type,
        folderId: parent,
        isFavorite: fav,
        isEncrypted: enc,
        isShared: shared,
        isChunked: size > 20 * 1024 * 1024,
      );
    }

    const mb = 1024 * 1024;

    folder('f-design', 'Design assets', items: 48, size: 2150 * mb, fav: true);
    folder('f-docs', 'Documents', items: 26, size: 340 * mb, days: 0);
    folder('f-media', 'Media', items: 112, size: 21400 * mb, days: 5);
    folder('f-archive', 'Archive', items: 9, size: 1200 * mb, days: 40);

    file(
      'a1',
      'Q3 architecture review.pdf',
      FileType.document,
      2513920,
      days: 0,
      enc: true,
      fav: true,
    );
    file('a2', 'launch-teaser-final.mp4', FileType.video, 432013312, days: 1);
    file('a3', 'IMG_20260731_sunset.heic', FileType.image, 5033164, days: 1);
    file('a4', 'interview-notes.m4a', FileType.audio, 19084083, days: 3);
    file(
      'a5',
      'nimbus-backup-2026-07.zip',
      FileType.archive,
      1288490188,
      days: 6,
      enc: true,
    );
    file(
      'a6',
      'invoice-2026-07.pdf',
      FileType.document,
      184320,
      days: 8,
      shared: true,
    );
    file('a7', 'roadmap.xlsx', FileType.other, 71680, days: 12);

    file(
      'd1',
      'logo-primary.svg',
      FileType.image,
      18432,
      parent: 'f-design',
      days: 2,
    );
    file(
      'd2',
      'brand-guide.pdf',
      FileType.document,
      8912896,
      parent: 'f-design',
      days: 4,
      fav: true,
    );
    file(
      'd3',
      'mockup-home.png',
      FileType.image,
      3145728,
      parent: 'f-design',
      days: 2,
      hours: 3,
    );
    file(
      'd4',
      'motion-study.mp4',
      FileType.video,
      88080384,
      parent: 'f-design',
      days: 9,
    );
    folder(
      'f-design-old',
      'Archive 2025',
      parent: 'f-design',
      items: 14,
      size: 512 * mb,
      days: 120,
    );

    file(
      'm1',
      'wedding-full.mov',
      FileType.video,
      2040109465,
      parent: 'f-media',
      days: 20,
    );
    file(
      'm2',
      'podcast-ep12.mp3',
      FileType.audio,
      41943040,
      parent: 'f-media',
      days: 7,
    );

    file(
      'x1',
      'contract-signed.pdf',
      FileType.document,
      2411724,
      parent: 'f-docs',
      days: 0,
      hours: 2,
      enc: true,
    );
    file(
      'x2',
      'passport-scan.jpg',
      FileType.image,
      1887436,
      parent: 'f-docs',
      days: 30,
      enc: true,
    );
  }
}
