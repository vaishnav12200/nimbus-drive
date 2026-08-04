import 'dart:typed_data';

/// A file the user chose, held in memory until it is sent.
///
/// Bytes rather than a path: the direct route hands the whole body to the
/// Telegram Bot API in one request, and the size ceiling for that route is
/// 20 MB — small enough to hold. Files large enough for the streaming route are
/// re-read from disk when that path learns to stream, which is the change this
/// class is shaped to allow.
class PickedFile {
  const PickedFile({
    required this.name,
    required this.bytes,
    this.mimeType = 'application/octet-stream',
  });

  final String name;
  final Uint8List bytes;
  final String mimeType;

  int get size => bytes.length;
}
