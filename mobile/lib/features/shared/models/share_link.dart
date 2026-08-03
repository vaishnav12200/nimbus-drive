import '../../files/models/drive_item.dart';

/// A public link to one file.
///
/// Mirrors `shared_links` in the backend: a token, optional expiry, optional
/// download cap, optional password. Every one of those is optional server-side,
/// so every one of them is nullable here rather than defaulted into a lie.
class ShareLink {
  const ShareLink({
    required this.id,
    required this.token,
    required this.fileName,
    required this.fileType,
    required this.fileSize,
    required this.createdAt,
    this.expiresAt,
    this.maxDownloads,
    this.downloadCount = 0,
    this.hasPassword = false,
  });

  final String id;
  final String token;
  final String fileName;
  final FileType fileType;
  final int fileSize;
  final DateTime createdAt;

  /// Null means it never expires.
  final DateTime? expiresAt;

  /// Null means unlimited.
  final int? maxDownloads;

  final int downloadCount;
  final bool hasPassword;

  String get url => 'https://nimbus.example/s/$token';

  bool get isExpired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now());

  bool get isExhausted =>
      maxDownloads != null && downloadCount >= maxDownloads!;

  /// The server answers `SHARE_EXPIRED` for both cases, so they are one state
  /// here too — a link that has run out of downloads is as dead as one past
  /// its date, and telling them apart helps nobody.
  bool get isDead => isExpired || isExhausted;

  /// Whole days left, or null when it never expires. Negative once past.
  int? get daysRemaining =>
      expiresAt?.difference(DateTime.now()).inHours == null
      ? null
      : (expiresAt!.difference(DateTime.now()).inHours / 24).floor();
}
