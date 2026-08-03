import 'package:flutter/foundation.dart';

import '../files/data/file_repository.dart';
import 'models/account.dart';

abstract interface class SettingsRepository {
  Future<Account> load();

  /// Runs the server's `getMe` + `getChat` + test-message check.
  ///
  /// Returns the server's own message either way. `POST /telegram/test`
  /// answers 200 with `ok: false` when Telegram refuses — a misconfigured
  /// channel is user feedback, not a server error — so this returns a result
  /// rather than throwing.
  Future<TelegramTestResult> testTelegram();

  Future<void> signOut();

  Future<void> signOutEverywhere();
}

class TelegramTestResult {
  const TelegramTestResult({required this.ok, required this.detail});

  final bool ok;
  final String detail;
}

class InMemorySettingsRepository implements SettingsRepository {
  /// Takes the drive so storage and encryption figures come from the same
  /// place Home and Files read. Hardcoding them here is how Settings ended up
  /// claiming 48 GB while Home showed 3.7 GB of the same drive.
  InMemorySettingsRepository(
    this._drive, {
    this.latency = const Duration(milliseconds: 380),
  });

  final FileRepository _drive;
  final Duration latency;

  @override
  Future<Account> load() async {
    await Future<void>.delayed(latency);
    final summary = await _drive.summary();

    return Account(
      // Placeholder, deliberately not a real address: this file is committed
      // to a public repository.
      displayName: 'Nimbus User',
      email: 'you@example.com',
      storageUsed: summary.storageUsed,
      storageQuota: summary.storageQuota,
      telegram: TelegramBinding(
        channelName: 'Nimbus Vault',
        channelId: -1001234567890,
        maskedBotToken: '7284••••••••••••••••••••••••••AbCd',
        lastTestedAt: DateTime.now().subtract(const Duration(hours: 5)),
        isActive: true,
      ),
      encryption: EncryptionState(
        enabled: true,
        encryptedFileCount: summary.encryptedCount,
      ),
      sessions: [
        Session(
          id: 'se1',
          device: 'Pixel 8 · Android 15',
          lastSeen: DateTime.now(),
          location: 'Kochi, IN',
          isCurrent: true,
        ),
        Session(
          id: 'se2',
          device: 'Chrome · Fedora 43',
          lastSeen: DateTime.now().subtract(const Duration(hours: 3)),
          location: 'Kochi, IN',
        ),
        Session(
          id: 'se3',
          device: 'iPad Air',
          lastSeen: DateTime.now().subtract(const Duration(days: 4)),
          location: 'Bengaluru, IN',
        ),
      ],
    );
  }

  @override
  Future<TelegramTestResult> testTelegram() async {
    await Future<void>.delayed(latency);
    return const TelegramTestResult(
      ok: true,
      detail: 'Posted a test message to Nimbus Vault',
    );
  }

  @override
  Future<void> signOut() => Future<void>.delayed(latency);

  @override
  Future<void> signOutEverywhere() => Future<void>.delayed(latency);
}

class SettingsController extends ChangeNotifier {
  SettingsController(this._repository) {
    load();
  }

  final SettingsRepository _repository;

  Account? _account;
  bool _loading = true;
  String? _error;
  bool _testing = false;

  Account? get account => _account;
  bool get loading => _loading;
  String? get error => _error;
  bool get testing => _testing;

  Future<void> load() async {
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      _account = await _repository.load();
    } catch (e) {
      _error = '$e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<TelegramTestResult> testTelegram() async {
    _testing = true;
    notifyListeners();
    try {
      return await _repository.testTelegram();
    } finally {
      _testing = false;
      notifyListeners();
    }
  }

  Future<void> signOut() => _repository.signOut();

  Future<void> signOutEverywhere() => _repository.signOutEverywhere();
}
