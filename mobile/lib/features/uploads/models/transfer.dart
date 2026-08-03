import '../../../core/widgets/nimbus_transfer_row.dart';
import '../../files/models/drive_item.dart';

/// Telegram's own limit for the Bot API. Files at or under it go straight from
/// the device; anything larger has to be streamed through the backend and cut
/// into chunks, which is a materially different — and much slower — journey.
const int kDirectUploadLimit = 20 * 1024 * 1024;

/// How a file reaches Telegram.
enum TransferRoute {
  /// Device → Telegram Bot API. The bytes never touch the Nimbus server.
  direct('Direct to Telegram'),

  /// Device → Nimbus → MTProto, cut into 19 MB chunks on the way.
  chunked('Chunked via server');

  const TransferRoute(this.label);

  final String label;
}

enum TransferDirection { upload, download }

/// One file in flight.
class Transfer {
  const Transfer({
    required this.id,
    required this.name,
    required this.type,
    required this.totalBytes,
    this.sentBytes = 0,
    this.state = TransferState.queued,
    this.direction = TransferDirection.upload,
    this.error,
    this.chunkIndex,
    this.retryAfter,
  });

  final String id;
  final String name;
  final FileType type;
  final int totalBytes;
  final int sentBytes;
  final TransferState state;
  final TransferDirection direction;

  /// Server message for a failure, shown verbatim — `docs/API.md` writes these
  /// for humans, so paraphrasing only loses detail.
  final String? error;

  /// Which chunk is moving, for [TransferRoute.chunked] transfers.
  final int? chunkIndex;

  /// Seconds to wait after a `FLOOD_WAIT`, counted down in the row.
  final int? retryAfter;

  TransferRoute get route => totalBytes > kDirectUploadLimit
      ? TransferRoute.chunked
      : TransferRoute.direct;

  /// 19 MB segments, matching the backend's chunker.
  int get chunkCount => route == TransferRoute.direct
      ? 1
      : (totalBytes / (19 * 1024 * 1024)).ceil();

  /// Fraction transferred, or null when it genuinely cannot be known.
  ///
  /// Queued returns 0 rather than null on purpose: a null makes the bar
  /// *indeterminate*, and a bar sweeping back and forth beside "waiting for
  /// capacity" says the opposite of what is happening. An empty track is the
  /// honest picture of a transfer that has not started.
  double? get progress =>
      totalBytes == 0 ? null : (sentBytes / totalBytes).clamp(0.0, 1.0);

  bool get isFinished =>
      state == TransferState.done || state == TransferState.failed;

  bool get isActive => !isFinished;

  Transfer copyWith({
    int? sentBytes,
    TransferState? state,
    String? error,
    int? chunkIndex,
    int? retryAfter,
  }) => Transfer(
    id: id,
    name: name,
    type: type,
    totalBytes: totalBytes,
    sentBytes: sentBytes ?? this.sentBytes,
    state: state ?? this.state,
    direction: direction,
    error: error ?? this.error,
    chunkIndex: chunkIndex ?? this.chunkIndex,
    retryAfter: retryAfter ?? this.retryAfter,
  );
}
