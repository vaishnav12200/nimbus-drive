import 'package:flutter_test/flutter_test.dart';
import 'package:nimbus_drive/features/files/data/in_memory_file_repository.dart';
import 'package:nimbus_drive/features/settings/settings_controller.dart';

InMemoryFileRepository _drive() =>
    InMemoryFileRepository(latency: Duration.zero);

void main() {
  test('storage figures agree with the drive Home and Files read', () async {
    final drive = _drive();
    final settings = InMemorySettingsRepository(drive, latency: Duration.zero);

    final account = await settings.load();
    final summary = await drive.summary();

    // These were hardcoded once and drifted: Settings claimed 48 GB while Home
    // showed 3.7 GB of the same drive.
    expect(account.storageUsed, summary.storageUsed);
    expect(account.storageQuota, summary.storageQuota);
    expect(account.encryption.encryptedFileCount, summary.encryptedCount);
  });

  test('a deletion moves both numbers together', () async {
    final drive = _drive();
    final settings = InMemorySettingsRepository(drive, latency: Duration.zero);

    final before = await settings.load();
    await drive.delete('a2'); // 412 MB video

    final after = await settings.load();
    expect(after.storageUsed, lessThan(before.storageUsed));
    expect(after.storageUsed, (await drive.summary()).storageUsed);
  });

  test('session count is derived, not stored separately', () async {
    final account = await InMemorySettingsRepository(
      _drive(),
      latency: Duration.zero,
    ).load();

    expect(account.activeSessions, account.sessions.length);
    expect(account.sessions.where((s) => s.isCurrent), hasLength(1));
  });

  test(
    'telegram test returns the server message rather than throwing',
    () async {
      // POST /telegram/test answers 200 with ok:false when Telegram refuses, so
      // a refusal must arrive as a result the UI can show.
      final result = await InMemorySettingsRepository(
        _drive(),
        latency: Duration.zero,
      ).testTelegram();

      expect(result.detail, isNotEmpty);
    },
  );
}
