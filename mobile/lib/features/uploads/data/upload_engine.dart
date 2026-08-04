import 'dart:async';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/widgets/nimbus_transfer_row.dart';
import '../../files/models/drive_item.dart';
import '../../telegram/data/bot_token_store.dart';
import '../../telegram/data/telegram_repository.dart';
import '../models/picked_file.dart';
import '../models/transfer.dart';
import 'telegram_bot_client.dart';
import 'transfer_repository.dart';

/// The real upload pipeline.
///
/// Two routes, decided by size, exactly as `docs/ARCHITECTURE.md` §3 describes:
///
/// * **≤ 20 MB** — the bytes go from this device straight to the Telegram Bot
///   API, then `POST /files` records where they landed. The server never sees
///   them.
/// * **> 20 MB** — `POST /files/reserve` gets an id first, then the bytes are
///   streamed to `POST /files/{id}/upload`, which chunks them over MTProto.
///
/// One file moves at a time. Telegram rate-limits a bot hard enough that
/// parallel uploads trade a modest speed-up for `FLOOD_WAIT` responses that
/// stall everything.
class UploadEngine implements TransferRepository {
  UploadEngine(
    this._api,
    this._telegram,
    this._botTokens, {
    TelegramBotClient? bot,
  }) : _bot = bot ?? TelegramBotClient();

  final ApiClient _api;
  final TelegramRepository _telegram;
  final BotTokenStore _botTokens;
  final TelegramBotClient _bot;

  final _transfers = <Transfer>[];
  final _payloads = <String, PickedFile>{};
  final _controller = StreamController<List<Transfer>>.broadcast();
  final _cancelled = <String>{};

  bool _running = false;

  @override
  Stream<List<Transfer>> watch() => _controller.stream;

  @override
  List<Transfer> get current => List.unmodifiable(_transfers);

  void _emit() {
    if (!_controller.isClosed) _controller.add(List.unmodifiable(_transfers));
  }

  int _indexOf(String id) => _transfers.indexWhere((t) => t.id == id);

  void _update(String id, Transfer Function(Transfer) change) {
    final i = _indexOf(id);
    if (i < 0) return;
    _transfers[i] = change(_transfers[i]);
    _emit();
  }

  /// Queues [file] and starts the pump if it is idle.
  @override
  Future<void> enqueue(PickedFile file) async {
    final id =
        'tr-${DateTime.now().microsecondsSinceEpoch}-${file.name.hashCode}';

    _payloads[id] = file;
    _transfers.insert(
      0,
      Transfer(
        id: id,
        name: file.name,
        type: fileTypeFromMime(file.mimeType, file.name),
        totalBytes: file.size,
      ),
    );
    _emit();
    unawaited(_pump());
  }

  /// Works the queue one file at a time until nothing is left.
  Future<void> _pump() async {
    if (_running) return;
    _running = true;

    try {
      while (true) {
        final next = _transfers.where(
          (t) => t.state == TransferState.queued && _payloads.containsKey(t.id),
        );
        if (next.isEmpty) break;

        // Oldest first: the queue is a queue, even though the list renders
        // newest at the top.
        await _send(next.last);
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _send(Transfer transfer) async {
    final file = _payloads[transfer.id];
    if (file == null) return;

    _update(transfer.id, (t) => t.copyWith(state: TransferState.running));

    try {
      // Hashed before anything is sent, and always over the *plaintext* —
      // `docs/API.md` is explicit that this is what lets an encrypted upload
      // deduplicate against its unencrypted twin.
      final digest = sha256.convert(file.bytes).toString();

      final existing = await _findDuplicate(digest);
      if (existing != null) {
        _finish(transfer.id, detail: 'Already in your drive as "$existing"');
        return;
      }

      if (file.size <= kDirectUploadLimit) {
        await _sendDirect(transfer.id, file, digest);
      } else {
        await _sendViaBackend(transfer.id, file, digest);
      }
    } on ApiException catch (e) {
      if (_cancelled.remove(transfer.id)) return;
      _update(
        transfer.id,
        (t) => t.copyWith(
          state: TransferState.failed,
          error: e.message,
          retryAfter: e.retryAfter ?? 0,
        ),
      );
    } catch (e) {
      if (_cancelled.remove(transfer.id)) return;
      _update(
        transfer.id,
        (t) => t.copyWith(state: TransferState.failed, error: '$e'),
      );
    }
  }

  /// Asks the server whether these bytes are already stored.
  ///
  /// Cheap next to an upload, and on a phone connection skipping a duplicate is
  /// the single biggest saving available.
  Future<String?> _findDuplicate(String sha256Hex) async {
    try {
      final data = await _api.get<Map<String, dynamic>>(
        '/files/dedup',
        query: {'sha256': sha256Hex},
        parse: (d) => d as Map<String, dynamic>,
      );
      return data['found'] == true ? data['name'] as String? : null;
    } on ApiException {
      // A dedup lookup that fails must not stop the upload.
      return null;
    }
  }

  Future<void> _sendDirect(String id, PickedFile file, String digest) async {
    final token = await _botTokens.read();
    final binding = await _telegram.read();

    if (token == null || binding?.channelId == null) {
      throw const ApiException(
        code: ApiErrorCode.telegramNotConfigured,
        message: 'Connect a Telegram channel before uploading',
      );
    }

    final sent = await _bot.sendDocument(
      botToken: token,
      channelId: binding!.channelId!,
      fileName: file.name,
      bytes: file.bytes,
      onProgress: (moved, _) =>
          _update(id, (t) => t.copyWith(sentBytes: moved)),
    );

    // The bytes exist in Telegram now; this row is what makes them findable.
    // If it fails the message is orphaned, which is the trade the architecture
    // documents for keeping small uploads off the server.
    await _api.post<dynamic>(
      '/files',
      body: {
        'name': file.name,
        'size': file.size,
        'mime_type': file.mimeType,
        'sha256': digest,
        'telegram_message_id': sent.messageId,
        'telegram_file_id': ?sent.fileId,
        'telegram_file_unique_id': ?sent.fileUniqueId,
      },
    );

    _finish(id, detail: null);
  }

  Future<void> _sendViaBackend(
    String id,
    PickedFile file,
    String digest,
  ) async {
    // Reserve first: the row exists before a byte moves, so progress and
    // retries have something to attach to.
    final reserved = await _api.post<Map<String, dynamic>>(
      '/files/reserve',
      body: {
        'name': file.name,
        'size': file.size,
        'mime_type': file.mimeType,
        'sha256': digest,
      },
      parse: (d) => d as Map<String, dynamic>,
    );

    final fileId = reserved['id'] as String;

    // Raw body, not multipart: `docs/API.md` notes the multipart parser spools
    // the part to disk before the backend copies it, costing twice the staging
    // space on a server that caps it.
    await _api.raw.post<dynamic>(
      '/files/$fileId/upload',
      data: Stream<List<int>>.fromIterable([file.bytes]),
      options: Options(
        headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Length': file.size,
        },
      ),
      onSendProgress: (moved, _) {
        final chunk = (moved / (19 * 1024 * 1024)).ceil();
        _update(id, (t) => t.copyWith(sentBytes: moved, chunkIndex: chunk));
      },
    );

    _finish(id, detail: null);
  }

  void _finish(String id, {String? detail}) {
    _payloads.remove(id);
    _update(
      id,
      (t) => t.copyWith(
        state: TransferState.done,
        sentBytes: t.totalBytes,
        error: detail,
      ),
    );
  }

  @override
  Future<void> cancel(String id) async {
    _cancelled.add(id);
    _payloads.remove(id);
    _transfers.removeWhere((t) => t.id == id);
    _emit();
  }

  @override
  Future<void> retry(String id) async {
    if (!_payloads.containsKey(id)) {
      // The bytes are gone, so there is nothing to resend. Saying so beats a
      // retry that silently does nothing.
      _update(
        id,
        (t) => t.copyWith(
          state: TransferState.failed,
          error: 'Pick the file again to retry',
        ),
      );
      return;
    }
    _update(
      id,
      (t) => t.copyWith(state: TransferState.queued, retryAfter: 0, error: ''),
    );
    unawaited(_pump());
  }

  @override
  Future<void> pause(String id) async =>
      _update(id, (t) => t.copyWith(state: TransferState.paused));

  @override
  Future<void> resume(String id) async {
    _update(id, (t) => t.copyWith(state: TransferState.queued));
    unawaited(_pump());
  }

  @override
  Future<void> clearCompleted() async {
    _transfers.removeWhere((t) => t.state == TransferState.done);
    _emit();
  }

  @override
  void dispose() {
    _controller.close();
  }
}
