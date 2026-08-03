import '../../../core/network/api_client.dart';
import '../../files/models/drive_item.dart';
import '../models/share_link.dart';
import 'share_repository.dart';

class ApiShareRepository implements ShareRepository {
  ApiShareRepository(this._api);

  final ApiClient _api;

  @override
  Future<List<ShareLink>> list() async {
    final page = await _api.getPage('/shares', query: {'limit': 100});
    return [for (final item in page.items) _from(item as Map<String, dynamic>)];
  }

  @override
  Future<void> revoke(String id) => _api.delete<dynamic>('/shares/$id');

  static ShareLink _from(Map<String, dynamic> json) {
    // The link row carries the file it points at; how deeply depends on the
    // serializer, so both a nested object and flat columns are accepted.
    final file = json['file'] as Map<String, dynamic>?;
    final name =
        file?['name'] as String? ?? json['file_name'] as String? ?? 'File';
    final mime = file?['mime_type'] as String? ?? json['mime_type'] as String?;

    return ShareLink(
      id: json['id'] as String,
      token: json['token'] as String? ?? '',
      fileName: name,
      fileType: fileTypeFromMime(mime, name),
      fileSize:
          (file?['size'] as num?)?.toInt() ??
          (json['file_size'] as num?)?.toInt() ??
          0,
      createdAt: _time(json['created_at']),
      expiresAt: json['expires_at'] == null ? null : _time(json['expires_at']),
      maxDownloads: (json['max_downloads'] as num?)?.toInt(),
      downloadCount: (json['download_count'] as num?)?.toInt() ?? 0,
      // The server never returns the hash, only whether one exists.
      hasPassword:
          json['has_password'] as bool? ?? json['password_hash'] != null,
    );
  }

  static DateTime _time(Object? value) =>
      DateTime.tryParse('$value')?.toLocal() ?? DateTime.now();
}
