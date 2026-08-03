import '../models/drive_item.dart';
import '../models/file_query.dart';

/// A folder and what is in it.
class FolderListing {
  const FolderListing({
    required this.items,
    required this.breadcrumbs,
    this.folder,
  });

  final List<DriveItem> items;

  /// Root first, current folder last. Empty at the drive root.
  final List<DriveFolder> breadcrumbs;

  /// Null at the root.
  final DriveFolder? folder;
}

/// What the Files screen needs from storage.
///
/// The screen depends on this interface and never on an implementation, so
/// wiring the real backend later is a second class rather than a rewrite of
/// the UI. The method set is deliberately shaped like `docs/API.md` —
/// `folder_id: null` meaning root, soft delete, favourite as a PATCH — so the
/// HTTP implementation is a translation and not a redesign.
abstract interface class FileRepository {
  /// [folderId] null lists the drive root.
  Future<FolderListing> list({String? folderId, required FileQuery query});

  Future<void> rename(String id, String name);

  Future<void> setFavorite(String id, bool value);

  /// Soft delete — the backend moves files to the trash and keeps the bytes.
  Future<void> delete(String id);

  /// Creates a share link and returns its URL.
  ///
  /// Throws [ShareNotAllowed] for an encrypted file, mirroring the server's
  /// `CANNOT_SHARE_ENCRYPTED`: the recipient has no key, so the link would
  /// deliver unreadable ciphertext.
  Future<String> createShareLink(String fileId);

  Future<DriveFolder> createFolder({String? parentId, required String name});
}

class ShareNotAllowed implements Exception {
  const ShareNotAllowed(this.message);

  final String message;

  @override
  String toString() => message;
}

class DuplicateName implements Exception {
  const DuplicateName(this.message);

  final String message;

  @override
  String toString() => message;
}
