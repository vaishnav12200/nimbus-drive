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

/// The whole drive in one shape, for the Home screen.
///
/// One call rather than three: Home shows how full the drive is, what fills it
/// and what changed lately, and those numbers have to agree with each other.
/// Fetched separately they can disagree by a write that landed in between.
class DriveSummary {
  const DriveSummary({
    required this.storageUsed,
    required this.storageQuota,
    required this.bytesByType,
    required this.recent,
    required this.encryptedCount,
  });

  final int storageUsed;
  final int storageQuota;

  /// Bytes per category. Types with nothing in them are absent rather than
  /// zero, so the breakdown never renders an empty bar.
  final Map<FileType, int> bytesByType;

  /// Most recently touched files across every folder.
  final List<DriveFile> recent;

  /// How many files are client-side encrypted. Settings reports it, and it has
  /// to come from the same pass as the byte totals or the two screens disagree.
  final int encryptedCount;

  double get usedFraction =>
      storageQuota == 0 ? 0 : (storageUsed / storageQuota).clamp(0.0, 1.0);
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

  /// Totals and recent activity across the whole drive.
  Future<DriveSummary> summary({int recentLimit = 5});

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
