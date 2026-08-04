import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Where the bot token lives on this device.
///
/// The server stores its own copy encrypted and only ever returns a mask, so
/// this is not a cache of something retrievable — it is the *only* place the
/// client can get the token back. Without it there is no direct upload path:
/// `docs/ARCHITECTURE.md` §3 has files at or under 20 MB going straight from
/// the device to the Bot API, which needs the token in full.
///
/// That makes it a real credential at rest, hence the keychain rather than
/// preferences.
abstract interface class BotTokenStore {
  Future<String?> read();

  Future<void> write(String token);

  Future<void> clear();
}

class SecureBotTokenStore implements BotTokenStore {
  SecureBotTokenStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          );

  final FlutterSecureStorage _storage;

  static const _key = 'nimbus.telegram_bot_token';

  @override
  Future<String?> read() => _storage.read(key: _key);

  @override
  Future<void> write(String token) => _storage.write(key: _key, value: token);

  @override
  Future<void> clear() => _storage.delete(key: _key);
}

/// Process-lifetime storage, for tests and the web review build.
class InMemoryBotTokenStore implements BotTokenStore {
  String? _token;

  @override
  Future<String?> read() async => _token;

  @override
  Future<void> write(String token) async => _token = token;

  @override
  Future<void> clear() async => _token = null;
}

BotTokenStore createBotTokenStore() =>
    kIsWeb ? InMemoryBotTokenStore() : SecureBotTokenStore();
