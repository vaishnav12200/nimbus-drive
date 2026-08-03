import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../auth/auth_controller.dart';
import '../../files/data/file_repository.dart';
import '../models/account.dart';
import '../settings_controller.dart';

/// Settings, assembled from the four endpoints that describe an account.
///
/// `/auth/me`, `/auth/sessions`, `/telegram/config` and the drive summary are
/// separate calls but one screen, so they are fetched together and merged here
/// rather than leaving four loading states in the UI.
class ApiSettingsRepository implements SettingsRepository {
  ApiSettingsRepository(this._api, this._drive, this._auth);

  final ApiClient _api;
  final FileRepository _drive;
  final AuthController _auth;

  @override
  Future<Account> load() async {
    final results = await Future.wait([
      _api.get<Map<String, dynamic>>(
        '/auth/me',
        parse: (d) => d as Map<String, dynamic>,
      ),
      _drive.summary(),
      _telegram(),
      _sessions(),
    ]);

    final me = results[0] as Map<String, dynamic>;
    final summary = results[1] as DriveSummary;
    final telegram = results[2] as TelegramBinding;
    final sessions = results[3] as List<Session>;

    return Account(
      displayName: (me['display_name'] as String?)?.trim().isNotEmpty == true
          ? me['display_name'] as String
          : (me['email'] as String).split('@').first,
      email: me['email'] as String,
      storageUsed: summary.storageUsed,
      storageQuota: summary.storageQuota,
      telegram: telegram,
      encryption: EncryptionState(
        enabled: me['encryption_enabled'] as bool? ?? false,
        encryptedFileCount: summary.encryptedCount,
      ),
      sessions: sessions,
    );
  }

  /// An unbound account is the normal state before onboarding, not an error —
  /// `TELEGRAM_NOT_CONFIGURED` is a 404 that the screen renders as a call to
  /// action rather than a failure.
  Future<TelegramBinding> _telegram() async {
    try {
      final data = await _api.get<Map<String, dynamic>>(
        '/telegram/config',
        parse: (d) => d as Map<String, dynamic>,
      );
      return TelegramBinding(
        channelName: data['channel_name'] as String?,
        channelId: (data['channel_id'] as num?)?.toInt(),
        maskedBotToken: data['bot_token'] as String?,
        lastTestedAt: data['last_tested_at'] == null
            ? null
            : DateTime.tryParse('${data['last_tested_at']}')?.toLocal(),
        isActive: data['is_active'] as bool? ?? false,
      );
    } on ApiException catch (e) {
      if (e.code == ApiErrorCode.telegramNotConfigured) {
        return const TelegramBinding();
      }
      rethrow;
    }
  }

  Future<List<Session>> _sessions() async {
    try {
      final list = await _auth.sessions();
      return [
        for (final s in list)
          Session(
            id: s.id,
            device: s.device,
            lastSeen: s.issuedAt,
            location: s.ipAddress,
            isCurrent: s.isCurrent,
          ),
      ];
    } on ApiException {
      // A settings screen that fails wholesale because the session list is
      // unavailable is worse than one that shows everything else.
      return const [];
    }
  }

  @override
  Future<TelegramTestResult> testTelegram() async {
    try {
      final data = await _api.post<Map<String, dynamic>>(
        '/telegram/test',
        parse: (d) => d as Map<String, dynamic>,
      );
      // 200 with ok:false is the documented shape for "Telegram refused" —
      // user feedback, not a server error, and the detail is written to show.
      return TelegramTestResult(
        ok: data['ok'] as bool? ?? false,
        detail: data['detail'] as String? ?? 'Connection tested',
      );
    } on ApiException catch (e) {
      return TelegramTestResult(ok: false, detail: e.message);
    }
  }

  @override
  Future<void> signOut() => _auth.signOut();

  @override
  Future<void> signOutEverywhere() => _auth.signOutEverywhere();
}
