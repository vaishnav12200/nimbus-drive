import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../models/drive_item.dart';
import '../models/file_query.dart';
import 'file_repository.dart';

/// The real drive, over HTTP.
///
/// Implements the same interface the in-memory fake does, so the screens are
/// untouched by the swap. What changes here is that folders and files are two
/// endpoints rather than one map, and the merge is this class's job.
class ApiFileRepository implements FileRepository {
  ApiFileRepository(this._api);

  final ApiClient _api;

  @override
  Future<FolderListing> list({
    String? folderId,
    required FileQuery query,
  }) async {
    // Folders and files come from different routes. Requested together so the
    // listing is one round trip's worth of latency, not two.
    final results = await Future.wait([
      _folders(folderId),
      _files(folderId, query),
      if (folderId != null) _breadcrumbs(folderId),
    ]);

    final folders = results[0] as List<DriveFolder>;
    final files = results[1] as List<DriveFile>;
    final trail = folderId == null
        ? const <DriveFolder>[]
        : results[2] as List<DriveFolder>;

    // The server sorts files; folders are merged in client-side, so the whole
    // list is re-sorted here to keep one ordering rule rather than two.
    final items = <DriveItem>[
      ...folders.where((f) => _matchesLocally(f, query)),
      ...files,
    ]..sort((a, b) => _compare(a, b, query));

    return FolderListing(
      items: items,
      breadcrumbs: trail,
      folder: trail.isEmpty ? null : trail.last,
    );
  }

  Future<List<DriveFolder>> _folders(String? parentId) => _api.get(
    '/folders',
    query: {'parent_id': ?parentId},
    parse: (d) => [
      for (final item in d as List<dynamic>)
        _folderFrom(item as Map<String, dynamic>),
    ],
  );

  Future<List<DriveFile>> _files(String? folderId, FileQuery query) async {
    // `/search` understands the filters; `/files` is the plain listing. Using
    // search only when there is something to search for keeps a bare folder
    // open off the trigram index.
    final filtered =
        query.search.isNotEmpty ||
        query.types.isNotEmpty ||
        query.favoritesOnly;

    final page = await _api.getPage(
      filtered ? '/search' : '/files',
      query: {
        'folder_id': ?folderId,
        if (folderId == null && !filtered) 'root': true,
        if (query.search.isNotEmpty) 'q': query.search,
        if (query.types.isNotEmpty)
          'type': query.types.map((t) => t.wire).join(','),
        if (query.favoritesOnly) 'is_favorite': true,
        'sort': query.sort.wire,
        'order': query.order.wire,
        'limit': 100,
      },
    );

    return [
      for (final item in page.items) _fileFrom(item as Map<String, dynamic>),
    ];
  }

  /// The trail from the root down to [folderId], inclusive.
  ///
  /// `GET /folders/{id}` returns `breadcrumbs` as *ancestors only* — an empty
  /// list for a folder at the root — so the folder itself is appended here.
  /// The screen titles itself from the last crumb, and without this every
  /// folder was titled after its parent.
  Future<List<DriveFolder>> _breadcrumbs(String folderId) async {
    final data = await _api.get<Map<String, dynamic>>(
      '/folders/$folderId',
      parse: (d) => d as Map<String, dynamic>,
    );

    final ancestors = data['breadcrumbs'];
    return [
      if (ancestors is List)
        for (final item in ancestors) _folderFrom(item as Map<String, dynamic>),
      _folderFrom(data),
    ];
  }

  bool _matchesLocally(DriveFolder folder, FileQuery query) {
    if (query.favoritesOnly && !folder.isFavorite) return false;
    if (query.search.isNotEmpty &&
        !folder.name.toLowerCase().contains(query.search.toLowerCase())) {
      return false;
    }
    // Type filters are about files; folders stay so the path remains walkable.
    return true;
  }

  int _compare(DriveItem a, DriveItem b, FileQuery query) {
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

  @override
  Future<DriveSummary> summary({int recentLimit = 5}) async {
    // `sort=updated_at&order=desc` gives recency; the byte totals need the
    // whole set, so this asks for a large page rather than paging through.
    final page = await _api.getPage(
      '/files',
      query: {'sort': 'updated_at', 'order': 'desc', 'limit': 500},
    );

    final files = [
      for (final item in page.items) _fileFrom(item as Map<String, dynamic>),
    ];

    final bytesByType = <FileType, int>{};
    for (final file in files) {
      bytesByType.update(
        file.type,
        (v) => v + file.size,
        ifAbsent: () => file.size,
      );
    }

    return DriveSummary(
      storageUsed: files.fold(0, (sum, f) => sum + f.size),
      storageQuota: kStorageQuota,
      bytesByType: bytesByType,
      recent: files.take(recentLimit).toList(),
      encryptedCount: files.where((f) => f.isEncrypted).length,
    );
  }

  @override
  Future<void> rename(String id, String name) async {
    // Folders and files rename through different routes, and only the caller's
    // list knows which this id is. Try file, fall back to folder.
    try {
      await _api.patch<dynamic>('/files/$id', body: {'name': name});
    } on ApiException catch (e) {
      if (e.code != ApiErrorCode.fileNotFound) rethrow;
      await _api.patch<dynamic>('/folders/$id', body: {'name': name});
    }
  }

  @override
  Future<void> setFavorite(String id, bool value) async {
    try {
      await _api.patch<dynamic>('/files/$id', body: {'is_favorite': value});
    } on ApiException catch (e) {
      if (e.code != ApiErrorCode.fileNotFound) rethrow;
      // Folders have no favourite flag server-side; silently succeeding would
      // leave the star lit until the next reload.
      throw const ApiException(
        code: 'UNSUPPORTED',
        message: 'Folders cannot be favourited yet',
      );
    }
  }

  @override
  Future<void> delete(String id) async {
    try {
      await _api.delete<dynamic>('/files/$id');
    } on ApiException catch (e) {
      if (e.code != ApiErrorCode.fileNotFound) rethrow;
      // Cascade: the screen only reaches this after an explicit confirmation
      // that says the contents go too.
      await _api.delete<dynamic>('/folders/$id', query: {'cascade': true});
    }
  }

  @override
  Future<String> createShareLink(String fileId) async {
    try {
      final data = await _api.post<Map<String, dynamic>>(
        '/shares',
        body: {'file_id': fileId},
        parse: (d) => d as Map<String, dynamic>,
      );
      return data['url'] as String? ?? _shareUrl(data['token'] as String?);
    } on ApiException catch (e) {
      if (e.code == ApiErrorCode.cannotShareEncrypted) {
        throw ShareNotAllowed(e.message);
      }
      rethrow;
    }
  }

  String _shareUrl(String? token) => token == null ? '' : '/s/$token';

  @override
  Future<DriveFolder> createFolder({
    String? parentId,
    required String name,
  }) async {
    final data = await _api.post<Map<String, dynamic>>(
      '/folders',
      body: {'name': name, 'parent_id': ?parentId},
      parse: (d) => d as Map<String, dynamic>,
    );
    return _folderFrom(data);
  }

  // --- Decoding -------------------------------------------------------------

  static DateTime _time(Object? value) =>
      DateTime.tryParse('$value')?.toLocal() ?? DateTime.now();

  static DriveFolder _folderFrom(Map<String, dynamic> json) => DriveFolder(
    id: json['id'] as String,
    name: json['name'] as String,
    updatedAt: _time(json['updated_at']),
    parentId: json['parent_id'] as String?,
    // The server counts files and subfolders separately; the row shows one
    // number, so they are summed here.
    itemCount:
        ((json['file_count'] as num?)?.toInt() ?? 0) +
        ((json['subfolder_count'] as num?)?.toInt() ?? 0),
    // Folders carry no aggregate size server-side. Zero means "unknown", and
    // the row omits it rather than claiming 0 B.
    size: (json['size'] as num?)?.toInt() ?? 0,
    isFavorite: json['is_favorite'] as bool? ?? false,
  );

  static DriveFile _fileFrom(Map<String, dynamic> json) => DriveFile(
    id: json['id'] as String,
    name: json['name'] as String,
    updatedAt: _time(json['updated_at']),
    size: (json['size'] as num?)?.toInt() ?? 0,
    // The server sends a MIME type, not a category, so the bucket is derived
    // here — the same mapping the breakdown and the filters rely on.
    type: fileTypeFromMime(
      json['mime_type'] as String?,
      json['name'] as String,
    ),
    folderId: json['folder_id'] as String?,
    isFavorite: json['is_favorite'] as bool? ?? false,
    isEncrypted: json['is_encrypted'] as bool? ?? false,
    isChunked: json['is_chunked'] as bool? ?? false,
  );
}
