import 'package:dio/dio.dart';

import '../../../core/network/api_exception.dart';

/// The result of handing a file to Telegram directly.
class SentDocument {
  const SentDocument({required this.messageId, this.fileId, this.fileUniqueId});

  final int messageId;
  final String? fileId;
  final String? fileUniqueId;
}

/// Uploads straight to the Telegram Bot API, bypassing the Nimbus server.
///
/// `docs/ARCHITECTURE.md` §3: files at or under 20 MB go client → Telegram and
/// never touch the backend. That is not an optimisation — it is the property
/// the whole design rests on, so this path exists rather than proxying
/// everything for uniformity.
///
/// Its own [Dio] with no interceptors: the Nimbus bearer token must never be
/// attached to a request going to Telegram.
class TelegramBotClient {
  TelegramBotClient({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://api.telegram.org',
              sendTimeout: const Duration(minutes: 5),
              receiveTimeout: const Duration(minutes: 5),
              validateStatus: (_) => true,
            ),
          );

  final Dio _dio;

  /// Sends [bytes] as a document to [channelId].
  ///
  /// Progress is reported as bytes sent, which for this path is the whole
  /// story — Telegram accepts the file in one request.
  Future<SentDocument> sendDocument({
    required String botToken,
    required int channelId,
    required String fileName,
    required List<int> bytes,
    void Function(int sent, int total)? onProgress,
  }) async {
    final form = FormData.fromMap({
      'chat_id': channelId,
      'document': MultipartFile.fromBytes(bytes, filename: fileName),
      // The channel is a storage bucket, not a feed; notifying on every file
      // would make it unusable.
      'disable_notification': true,
    });

    final response = await _dio.post<Map<String, dynamic>>(
      '/bot$botToken/sendDocument',
      data: form,
      onSendProgress: onProgress,
    );

    final body = response.data;
    if (body == null || body['ok'] != true) {
      throw _describe(body, response.statusCode);
    }

    final result = body['result'] as Map<String, dynamic>;
    final document = result['document'] as Map<String, dynamic>?;

    return SentDocument(
      messageId: (result['message_id'] as num).toInt(),
      fileId: document?['file_id'] as String?,
      fileUniqueId: document?['file_unique_id'] as String?,
    );
  }

  /// Turns Telegram's own error shape into the app's, so the upload queue has
  /// one failure type rather than two.
  static ApiException _describe(Map<String, dynamic>? body, int? status) {
    final description = body?['description'] as String? ?? 'Telegram refused';
    final parameters = body?['parameters'] as Map<String, dynamic>?;
    final retryAfter = (parameters?['retry_after'] as num?)?.toInt();

    // 429 carries `retry_after`; surfacing it is what lets the row count down
    // instead of just saying "failed".
    if (retryAfter != null) {
      return ApiException(
        code: ApiErrorCode.floodWait,
        message: 'Telegram is rate limiting the bot',
        details: {'retry_after': retryAfter},
        statusCode: status,
      );
    }

    final lower = description.toLowerCase();
    final code = switch (lower) {
      _ when lower.contains('chat not found') => 'CHANNEL_INVALID',
      _
          when lower.contains('not enough rights') ||
              lower.contains('need administrator') =>
        'CHAT_WRITE_FORBIDDEN',
      _ when lower.contains('unauthorized') => 'BOT_TOKEN_INVALID',
      _ when lower.contains('too large') => 'FILE_TOO_LARGE',
      _ => 'TELEGRAM_ERROR',
    };

    return ApiException(code: code, message: description, statusCode: status);
  }
}
