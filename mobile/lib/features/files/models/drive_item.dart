import 'package:flutter/material.dart';

/// Backend file categories, exactly the set `docs/API.md` documents for
/// `GET /api/search?type=`.
///
/// An enum rather than raw strings so a typo is a compile error, with [wire]
/// as the single translation point to and from the API.
enum FileType {
  image('image', Icons.image_rounded, 'Images'),
  video('video', Icons.movie_rounded, 'Video'),
  document('document', Icons.description_rounded, 'Documents'),
  audio('audio', Icons.graphic_eq_rounded, 'Audio'),
  archive('archive', Icons.folder_zip_rounded, 'Archives'),
  other('other', Icons.insert_drive_file_rounded, 'Other');

  const FileType(this.wire, this.icon, this.label);

  /// The string the API uses.
  final String wire;

  final IconData icon;
  final String label;

  /// Parses an API value, falling back to [other].
  ///
  /// The server may add a category before this client is rebuilt, and a file
  /// list is the wrong place to throw.
  static FileType fromWire(String value) =>
      values.firstWhere((t) => t.wire == value, orElse: () => other);
}

/// Anything that appears in a folder listing.
///
/// Sealed so a `switch` over it is exhaustive: the compiler catches the case
/// where a folder reaches code that assumed a file — which is where size and
/// MIME-type handling goes wrong.
sealed class DriveItem {
  const DriveItem({
    required this.id,
    required this.name,
    required this.updatedAt,
    required this.isFavorite,
  });

  final String id;
  final String name;
  final DateTime updatedAt;
  final bool isFavorite;

  /// Folders sort before files at equal rank, the convention every file
  /// manager uses.
  bool get isFolder => this is DriveFolder;
}

class DriveFolder extends DriveItem {
  const DriveFolder({
    required super.id,
    required super.name,
    required super.updatedAt,
    super.isFavorite = false,
    this.parentId,
    this.itemCount = 0,
    this.size = 0,
    this.color,
  });

  /// Null at the drive root. `docs/API.md` is explicit that a null parent
  /// means root rather than "unchanged", so the distinction is load-bearing.
  final String? parentId;

  final int itemCount;

  /// Total bytes beneath this folder, for display only.
  final int size;

  /// Optional user-chosen tint, matching the backend's `folders.color`.
  final Color? color;

  DriveFolder copyWith({String? name, bool? isFavorite}) => DriveFolder(
    id: id,
    name: name ?? this.name,
    updatedAt: updatedAt,
    isFavorite: isFavorite ?? this.isFavorite,
    parentId: parentId,
    itemCount: itemCount,
    size: size,
    color: color,
  );
}

class DriveFile extends DriveItem {
  const DriveFile({
    required super.id,
    required super.name,
    required super.updatedAt,
    required this.size,
    required this.type,
    super.isFavorite = false,
    this.folderId,
    this.isEncrypted = false,
    this.isShared = false,
    this.isChunked = false,
  });

  final int size;
  final FileType type;
  final String? folderId;

  /// Client-side encrypted. Shown as a lock, and blocks share-link creation —
  /// the backend rejects it with `CANNOT_SHARE_ENCRYPTED` because a recipient
  /// has no key.
  final bool isEncrypted;

  final bool isShared;

  /// Stored as multiple Telegram messages because it exceeded 20 MB.
  final bool isChunked;

  DriveFile copyWith({String? name, bool? isFavorite, bool? isShared}) =>
      DriveFile(
        id: id,
        name: name ?? this.name,
        updatedAt: updatedAt,
        size: size,
        type: type,
        isFavorite: isFavorite ?? this.isFavorite,
        folderId: folderId,
        isEncrypted: isEncrypted,
        isShared: isShared ?? this.isShared,
        isChunked: isChunked,
      );

  /// Name without its extension, for a rename field that should not make the
  /// user re-type ".pdf" or risk dropping it.
  String get baseName {
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  String get extension {
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? '' : name.substring(dot);
  }
}
