import 'dart:async';

// `show` matters: file_picker exports its own `FileType`, which would clash
// with the drive's category enum of the same name.
import 'package:file_picker/file_picker.dart' show FilePicker;
import 'package:flutter/foundation.dart';

import '../../core/widgets/nimbus_transfer_row.dart';
import 'data/transfer_repository.dart';
import 'models/picked_file.dart';
import 'models/transfer.dart';

/// State for the Upload screen.
class UploadsController extends ChangeNotifier {
  UploadsController(this._repository) {
    _transfers = _repository.current;
    _subscription = _repository.watch().listen((transfers) {
      _transfers = transfers;
      notifyListeners();
    });
  }

  final TransferRepository _repository;
  late final StreamSubscription<List<Transfer>> _subscription;

  List<Transfer> _transfers = const [];

  /// Where new uploads land. Null is the drive root.
  String destination = 'Nimbus';

  List<Transfer> get active =>
      _transfers.where((t) => t.isActive).toList(growable: false);

  List<Transfer> get failed => _transfers
      .where((t) => t.state == TransferState.failed)
      .toList(growable: false);

  List<Transfer> get completed => _transfers
      .where((t) => t.state == TransferState.done)
      .toList(growable: false);

  bool get isEmpty => _transfers.isEmpty;

  /// Combined progress across everything still moving, for the header summary.
  ///
  /// Weighted by bytes rather than by count: two files at 50% is not the same
  /// as a 1 GB file at 50% and a 2 MB file at 50%.
  double? get overallProgress {
    final moving = active.where((t) => t.state != TransferState.queued);
    if (moving.isEmpty) return null;

    final total = moving.fold<int>(0, (sum, t) => sum + t.totalBytes);
    if (total == 0) return null;

    final sent = moving.fold<int>(0, (sum, t) => sum + t.sentBytes);
    return sent / total;
  }

  int get activeCount => active.length;

  Future<void> cancel(Transfer t) => _repository.cancel(t.id);
  Future<void> retry(Transfer t) => _repository.retry(t.id);
  Future<void> pause(Transfer t) => _repository.pause(t.id);
  Future<void> resume(Transfer t) => _repository.resume(t.id);
  Future<void> clearCompleted() => _repository.clearCompleted();

  /// Opens the platform picker and queues whatever comes back.
  ///
  /// Returns the number of files added, so the caller can stay quiet when the
  /// user simply backed out of the picker — which is not an error and deserves
  /// no message.
  Future<int> pickFiles() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      // Bytes are needed either way: the direct route posts the whole body to
      // Telegram, and the picker on web has no path to fall back on.
      withData: true,
    );
    if (result == null) return 0;

    var added = 0;
    for (final file in result.files) {
      final bytes = file.bytes;
      if (bytes == null) continue;

      await _repository.enqueue(
        PickedFile(
          name: file.name,
          bytes: bytes,
          mimeType: _mimeFor(file.extension),
        ),
      );
      added++;
    }
    return added;
  }

  /// A best-effort MIME type from the extension.
  ///
  /// The server stores whatever it is told and the client buckets files by it,
  /// so a wrong guess only mislabels an icon — but `application/octet-stream`
  /// for every photo would put the whole library under "Other".
  static String _mimeFor(String? extension) =>
      switch (extension?.toLowerCase()) {
        'jpg' || 'jpeg' => 'image/jpeg',
        'png' => 'image/png',
        'gif' => 'image/gif',
        'webp' => 'image/webp',
        'heic' => 'image/heic',
        'svg' => 'image/svg+xml',
        'mp4' => 'video/mp4',
        'mov' => 'video/quicktime',
        'mkv' => 'video/x-matroska',
        'webm' => 'video/webm',
        'mp3' => 'audio/mpeg',
        'm4a' => 'audio/mp4',
        'wav' => 'audio/wav',
        'flac' => 'audio/flac',
        'pdf' => 'application/pdf',
        'txt' => 'text/plain',
        'md' => 'text/markdown',
        'csv' => 'text/csv',
        'zip' => 'application/zip',
        'tar' => 'application/x-tar',
        'gz' => 'application/gzip',
        '7z' => 'application/x-7z-compressed',
        'rar' => 'application/vnd.rar',
        _ => 'application/octet-stream',
      };

  @override
  void dispose() {
    _subscription.cancel();
    _repository.dispose();
    super.dispose();
  }
}
