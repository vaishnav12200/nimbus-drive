import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../settings/models/account.dart';

/// Result of `POST /telegram/test`.
///
/// The server answers **200 with `ok: false`** when Telegram refuses, because a
/// misconfigured channel is user feedback rather than a server fault. So this
/// is a value, not an exception, and `detail` is written to be shown as-is.
class TelegramTestResult {
  const TelegramTestResult({
    required this.ok,
    this.detail,
    this.botUsername,
    this.channelTitle,
  });

  factory TelegramTestResult.fromJson(Map<String, dynamic> json) =>
      TelegramTestResult(
        ok: json['ok'] as bool? ?? false,
        detail: json['detail'] as String?,
        botUsername: json['bot_username'] as String?,
        channelTitle: json['channel_title'] as String?,
      );

  final bool ok;
  final String? detail;
  final String? botUsername;
  final String? channelTitle;
}

abstract interface class TelegramRepository {
  /// The active binding, or null when none is configured.
  Future<TelegramBinding?> read();

  Future<TelegramBinding> bind({
    required String botToken,
    required int channelId,
    String? channelName,
  });

  Future<TelegramTestResult> test();

  Future<void> unbind();
}

class ApiTelegramRepository implements TelegramRepository {
  ApiTelegramRepository(this._api);

  final ApiClient _api;

  @override
  Future<TelegramBinding?> read() async {
    try {
      return _from(
        await _api.get<Map<String, dynamic>>(
          '/telegram/config',
          parse: (d) => d as Map<String, dynamic>,
        ),
      );
    } on ApiException catch (e) {
      // Not configured is a 404, and before onboarding that is the normal
      // state rather than a failure.
      if (e.code == ApiErrorCode.telegramNotConfigured) return null;
      rethrow;
    }
  }

  @override
  Future<TelegramBinding> bind({
    required String botToken,
    required int channelId,
    String? channelName,
  }) async {
    return _from(
      await _api.post<Map<String, dynamic>>(
        '/telegram/config',
        body: {
          'bot_token': botToken,
          'channel_id': channelId,
          'channel_name': ?channelName,
        },
        parse: (d) => d as Map<String, dynamic>,
      ),
    );
  }

  @override
  Future<TelegramTestResult> test() => _api.post<TelegramTestResult>(
    '/telegram/test',
    parse: (d) => TelegramTestResult.fromJson(d as Map<String, dynamic>),
  );

  @override
  Future<void> unbind() => _api.delete<dynamic>('/telegram/config');

  static TelegramBinding _from(Map<String, dynamic> json) => TelegramBinding(
    channelName: json['channel_name'] as String?,
    channelId: (json['channel_id'] as num?)?.toInt(),
    // `bot_token_masked`, never `bot_token` — reading the wrong key showed a
    // blank where the mask should be.
    maskedBotToken: json['bot_token_masked'] as String?,
    botUsername: json['bot_username'] as String?,
    lastTestedAt: json['last_tested_at'] == null
        ? null
        : DateTime.tryParse('${json['last_tested_at']}')?.toLocal(),
    lastTestOk: json['last_test_ok'] as bool?,
    isActive: json['is_active'] as bool? ?? false,
  );
}
