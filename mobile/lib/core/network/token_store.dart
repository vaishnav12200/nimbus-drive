import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// A token pair as `/auth/login` returns it.
@immutable
class TokenPair {
  const TokenPair({required this.accessToken, required this.refreshToken});

  final String accessToken;

  /// Opaque and single-use. Rotating consumes it; presenting a consumed one
  /// gets the whole session family revoked, so it must be replaced atomically.
  final String refreshToken;
}

/// Where the token pair lives between launches.
abstract interface class TokenStore {
  Future<TokenPair?> read();

  Future<void> write(TokenPair pair);

  Future<void> clear();
}

/// Keychain on iOS, EncryptedSharedPreferences on Android.
///
/// Refresh tokens are bearer credentials with a seven-day life — long enough
/// that plain preferences would be a real exposure on a rooted device.
class SecureTokenStore implements TokenStore {
  SecureTokenStore({FlutterSecureStorage? storage})
    : _storage =
          storage ??
          const FlutterSecureStorage(
            // Android encrypts by default now; the old
            // `encryptedSharedPreferences` flag is deprecated and ignored.
            // `first_unlock` rather than `first_unlock_this_device` so the
            // session survives a restore to a new phone, which is the same
            // trust boundary the refresh token already has.
            iOptions: IOSOptions(
              accessibility: KeychainAccessibility.first_unlock,
            ),
          );

  final FlutterSecureStorage _storage;

  static const _accessKey = 'nimbus.access_token';
  static const _refreshKey = 'nimbus.refresh_token';

  @override
  Future<TokenPair?> read() async {
    final access = await _storage.read(key: _accessKey);
    final refresh = await _storage.read(key: _refreshKey);
    if (access == null || refresh == null) return null;
    return TokenPair(accessToken: access, refreshToken: refresh);
  }

  @override
  Future<void> write(TokenPair pair) async {
    await _storage.write(key: _accessKey, value: pair.accessToken);
    await _storage.write(key: _refreshKey, value: pair.refreshToken);
  }

  @override
  Future<void> clear() async {
    await _storage.delete(key: _accessKey);
    await _storage.delete(key: _refreshKey);
  }
}

/// Process-lifetime storage, for tests and the web preview build.
///
/// Web has no keychain; `flutter_secure_storage` there is localStorage with a
/// key sitting beside it, which is not meaningfully secure. Since web is only
/// a review harness for this project, it forgets instead of pretending.
class InMemoryTokenStore implements TokenStore {
  TokenPair? _pair;

  @override
  Future<TokenPair?> read() async => _pair;

  @override
  Future<void> write(TokenPair pair) async => _pair = pair;

  @override
  Future<void> clear() async => _pair = null;
}

/// The store appropriate to the platform.
TokenStore createTokenStore() =>
    kIsWeb ? InMemoryTokenStore() : SecureTokenStore();
