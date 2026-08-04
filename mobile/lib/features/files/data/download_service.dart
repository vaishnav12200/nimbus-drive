import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/crypto/vault_envelope.dart';
import '../../../core/crypto/vault_key.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../models/drive_item.dart';

/// How the client should fetch a file, from `GET /files/{id}/ticket`.
class DownloadTicket {
  const DownloadTicket({
    required this.direct,
    required this.proxyUrl,
    required this.size,
    this.telegramFilePath,
    this.isEncrypted = false,
  });

  factory DownloadTicket.fromJson(Map<String, dynamic> json) => DownloadTicket(
    direct: json['mode'] == 'direct',
    proxyUrl: json['proxy_url'] as String? ?? '',
    size: (json['size'] as num?)?.toInt() ?? 0,
    telegramFilePath: json['telegram_file_path'] as String?,
    isEncrypted: json['is_encrypted'] as bool? ?? false,
  );

  /// True when the bytes can come straight from Telegram, bypassing the server.
  final bool direct;

  final String proxyUrl;
  final int size;

  /// Useless without the bot token, which is why the server can return it.
  final String? telegramFilePath;

  final bool isEncrypted;
}

/// Fetches file bytes, decrypting when they are sealed.
///
/// Two sources, chosen by the ticket: straight from Telegram for a single
/// message under 20 MB, or through the backend for anything chunked. The caller
/// does not care which — that choice is the server's to make and this class's
/// to honour.
class DownloadService {
  DownloadService(this._api, {Dio? telegram, this.keyProvider})
    : _telegram =
          telegram ??
          Dio(
            BaseOptions(
              baseUrl: 'https://api.telegram.org',
              responseType: ResponseType.bytes,
              validateStatus: (_) => true,
            ),
          );

  final ApiClient _api;
  final Dio _telegram;

  /// Supplies the vault key. Null when the drive is locked, which is a
  /// recoverable state — the caller prompts and retries.
  final VaultKey? Function()? keyProvider;

  Future<DownloadTicket> ticket(String fileId) => _api.get<DownloadTicket>(
    '/files/$fileId/ticket',
    parse: (d) => DownloadTicket.fromJson(d as Map<String, dynamic>),
  );

  /// The whole file, decrypted if it was encrypted.
  ///
  /// [onProgress] reports bytes received against the *stored* size, which for
  /// an encrypted file is slightly larger than what comes back.
  Future<Uint8List> fetch(
    DriveFile file, {
    String? botToken,
    void Function(int received, int total)? onProgress,
  }) async {
    final ticket = await this.ticket(file.id);

    final bytes = ticket.direct && botToken != null
        ? await _fromTelegram(ticket, botToken, onProgress)
        : await _fromBackend(file.id, onProgress);

    if (!file.isEncrypted && !ticket.isEncrypted) return bytes;

    final key = keyProvider?.call();
    if (key == null) {
      throw const VaultLockedException();
    }
    return key.open(bytes);
  }

  Future<Uint8List> _fromTelegram(
    DownloadTicket ticket,
    String botToken,
    void Function(int, int)? onProgress,
  ) async {
    // The path alone is inert; combined with the token the client already holds
    // it addresses the file. That split is why the server can return one.
    final response = await _telegram.get<List<int>>(
      '/file/bot$botToken/${ticket.telegramFilePath}',
      onReceiveProgress: onProgress,
    );

    if (response.statusCode != 200 || response.data == null) {
      throw ApiException(
        code: 'TELEGRAM_ERROR',
        message: 'Telegram would not return the file',
        statusCode: response.statusCode,
      );
    }
    return Uint8List.fromList(response.data!);
  }

  Future<Uint8List> _fromBackend(
    String fileId,
    void Function(int, int)? onProgress,
  ) async {
    final response = await _api.raw.get<List<int>>(
      '/files/$fileId/download',
      options: Options(responseType: ResponseType.bytes),
      onReceiveProgress: onProgress,
    );

    if (response.statusCode != 200 && response.statusCode != 206) {
      throw ApiException(
        code: 'DOWNLOAD_FAILED',
        message: 'The server could not return this file',
        statusCode: response.statusCode,
      );
    }
    return Uint8List.fromList(response.data ?? const []);
  }

  /// One decrypted chunk of an encrypted file, without downloading the rest.
  ///
  /// This is the seek path. The header is fetched first — it is small and says
  /// where every chunk lives — then exactly one chunk's byte range is
  /// requested. A player asking to start at 40 minutes costs one 4 MiB read
  /// rather than the whole file.
  Future<Uint8List> fetchChunkAt(String fileId, int plaintextOffset) async {
    final key = keyProvider?.call();
    if (key == null) throw const VaultLockedException();

    // Enough for the fixed fields plus a generous number of IVs; the exact
    // header length is only knowable after reading the chunk count.
    final head = await _range(fileId, 0, 4096);
    final header = VaultHeader.parse(head);

    final index = VaultEnvelope.chunkForOffset(
      plaintextOffset,
      header.chunkSize,
    );
    if (index >= header.chunkCount) {
      throw const VaultFormatException('Offset is past the end of the file');
    }

    final start = header.ciphertextOffsetOfChunk(index);
    final chunk = await _range(
      fileId,
      start,
      start + header.ciphertextLengthOfChunk(index) - 1,
    );

    return key.openChunk(chunk, header: header, index: index);
  }

  /// A byte range through the backend, which answers 206 with `Content-Range`.
  Future<Uint8List> _range(String fileId, int start, int endInclusive) async {
    final response = await _api.raw.get<List<int>>(
      '/files/$fileId/download',
      options: Options(
        responseType: ResponseType.bytes,
        headers: {'Range': 'bytes=$start-$endInclusive'},
      ),
    );

    final data = response.data;
    if (data == null ||
        (response.statusCode != 206 && response.statusCode != 200)) {
      throw ApiException(
        code: 'RANGE_FAILED',
        message: 'The server did not return the requested range',
        statusCode: response.statusCode,
      );
    }
    return Uint8List.fromList(data);
  }
}

/// The file is encrypted and no key is held. Recoverable: prompt and retry.
class VaultLockedException implements Exception {
  const VaultLockedException();

  @override
  String toString() => 'This file is encrypted. Unlock your drive to open it.';
}
