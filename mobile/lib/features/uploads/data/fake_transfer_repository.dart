import 'dart:async';
import 'dart:math';

import '../../../core/widgets/nimbus_transfer_row.dart';
import '../../files/models/drive_item.dart';
import '../models/transfer.dart';
import 'transfer_repository.dart';

/// A transfer queue that actually moves, for building the screen before the
/// upload pipeline exists.
///
/// It models the parts the UI has to survive: a concurrency cap, chunk-by-chunk
/// progress on large files, and a `FLOOD_WAIT` failure with a countdown. A fake
/// where everything succeeds smoothly hides every state worth designing.
class FakeTransferRepository implements TransferRepository {
  FakeTransferRepository({this.seed = true}) {
    if (seed) _seed();
    _ticker = Timer.periodic(const Duration(milliseconds: 400), (_) => _tick());
  }

  final bool seed;

  /// Matches the backend's staging cap: beyond this, further uploads wait
  /// rather than all crawling at once.
  static const _maxConcurrent = 2;

  final _transfers = <Transfer>[];
  final _controller = StreamController<List<Transfer>>.broadcast();
  final _random = Random(7);

  late final Timer _ticker;

  /// Ids that have already been failed once, so a retry succeeds instead of
  /// looping the user through the same error forever.
  final _alreadyFailed = <String>{};

  @override
  Stream<List<Transfer>> watch() => _controller.stream;

  @override
  List<Transfer> get current => List.unmodifiable(_transfers);

  void _emit() {
    if (!_controller.isClosed) _controller.add(List.unmodifiable(_transfers));
  }

  int _indexOf(String id) => _transfers.indexWhere((t) => t.id == id);

  void _tick() {
    var running = _transfers
        .where((t) => t.state == TransferState.running)
        .length;

    for (var i = 0; i < _transfers.length; i++) {
      final t = _transfers[i];

      // Count a retry countdown down even while nothing is moving.
      if (t.state == TransferState.failed && (t.retryAfter ?? 0) > 0) {
        _transfers[i] = t.copyWith(retryAfter: t.retryAfter! - 1);
        continue;
      }

      if (t.state == TransferState.queued && running < _maxConcurrent) {
        _transfers[i] = t.copyWith(state: TransferState.running);
        running++;
        continue;
      }

      if (t.state != TransferState.running) continue;

      // Chunked uploads move in visible steps; small ones finish almost at
      // once, which is the honest difference between the two routes.
      final step = t.route == TransferRoute.direct
          ? t.totalBytes ~/ 3
          : (19 * 1024 * 1024) ~/ 4;

      final sent = min(t.totalBytes, t.sentBytes + step);
      final chunk = t.route == TransferRoute.chunked
          ? (sent / (19 * 1024 * 1024)).ceil().clamp(1, t.chunkCount)
          : null;

      // One large transfer trips Telegram's rate limit partway through, once.
      final trips =
          t.route == TransferRoute.chunked &&
          !_alreadyFailed.contains(t.id) &&
          sent > t.totalBytes * 0.6 &&
          _random.nextBool();

      if (trips) {
        _alreadyFailed.add(t.id);
        _transfers[i] = t.copyWith(
          state: TransferState.failed,
          sentBytes: sent,
          error: 'Telegram is rate limiting the bot',
          retryAfter: 24,
        );
        running--;
        continue;
      }

      _transfers[i] = sent >= t.totalBytes
          ? t.copyWith(
              sentBytes: sent,
              state: TransferState.done,
              chunkIndex: chunk,
            )
          : t.copyWith(sentBytes: sent, chunkIndex: chunk);

      if (sent >= t.totalBytes) running--;
    }

    _emit();
  }

  @override
  Future<void> enqueue({required String name, required int sizeBytes}) async {
    _transfers.insert(
      0,
      Transfer(
        id: 'tr-${DateTime.now().microsecondsSinceEpoch}',
        name: name,
        type: _typeFromName(name),
        totalBytes: sizeBytes,
      ),
    );
    _emit();
  }

  @override
  Future<void> cancel(String id) async {
    _transfers.removeWhere((t) => t.id == id);
    _emit();
  }

  @override
  Future<void> retry(String id) async {
    final i = _indexOf(id);
    if (i < 0) return;
    _transfers[i] = _transfers[i].copyWith(
      state: TransferState.queued,
      retryAfter: 0,
    );
    _emit();
  }

  @override
  Future<void> pause(String id) async {
    final i = _indexOf(id);
    if (i < 0) return;
    _transfers[i] = _transfers[i].copyWith(state: TransferState.paused);
    _emit();
  }

  @override
  Future<void> resume(String id) async {
    final i = _indexOf(id);
    if (i < 0) return;
    _transfers[i] = _transfers[i].copyWith(state: TransferState.queued);
    _emit();
  }

  @override
  Future<void> clearCompleted() async {
    _transfers.removeWhere((t) => t.state == TransferState.done);
    _emit();
  }

  @override
  void dispose() {
    _ticker.cancel();
    _controller.close();
  }

  static FileType _typeFromName(String name) {
    final ext = name.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' || 'png' || 'heic' || 'gif' || 'svg' => FileType.image,
      'mp4' || 'mov' || 'mkv' || 'webm' => FileType.video,
      'mp3' || 'm4a' || 'wav' || 'flac' => FileType.audio,
      'pdf' || 'doc' || 'docx' || 'txt' || 'md' => FileType.document,
      'zip' || 'tar' || 'gz' || '7z' || 'rar' => FileType.archive,
      _ => FileType.other,
    };
  }

  void _seed() {
    const mb = 1024 * 1024;
    _transfers.addAll([
      Transfer(
        id: 'tr-1',
        name: 'nimbus-backup-2026-08.zip',
        type: FileType.archive,
        totalBytes: 1228 * mb,
        sentBytes: 420 * mb,
        state: TransferState.running,
        chunkIndex: 23,
      ),
      Transfer(
        id: 'tr-2',
        name: 'launch-teaser-final.mp4',
        type: FileType.video,
        totalBytes: 412 * mb,
        sentBytes: 96 * mb,
        state: TransferState.running,
        chunkIndex: 6,
      ),
      Transfer(
        id: 'tr-3',
        name: 'IMG_20260803_beach.heic',
        type: FileType.image,
        totalBytes: 5 * mb,
      ),
      Transfer(
        id: 'tr-4',
        name: 'contract-signed.pdf',
        type: FileType.document,
        totalBytes: 2 * mb,
        sentBytes: 2 * mb,
        state: TransferState.done,
      ),
    ]);
  }
}
