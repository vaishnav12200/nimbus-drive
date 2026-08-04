import 'dart:convert';
import 'dart:typed_data';

import '../../../core/crypto/vault_key.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';

/// What the server knows about this account's encryption.
///
/// All public: a salt, a KDF and its cost, and an opaque verifier. None of it
/// is enough to recover the key without the password.
class EncryptionStatus {
  const EncryptionStatus({required this.enabled, this.params, this.verifier});

  final bool enabled;
  final VaultParams? params;

  /// Base64 of AES-256-GCM(known text). Null when setup never attached one, in
  /// which case a wrong password cannot be caught until a file fails to open.
  final String? verifier;

  bool get canUnlock => enabled && params != null;
}

abstract interface class EncryptionRepository {
  Future<EncryptionStatus> status();

  /// Enables encryption and mints the salt.
  ///
  /// Takes cost parameters rather than a [VaultParams], because there is no
  /// salt to supply — the server makes it, and the returned value is the one
  /// the key must be derived from.
  ///
  /// Enabling twice is a 409 by design: a second salt would orphan every file
  /// encrypted under the first, with no recovery path.
  Future<VaultParams> enable({
    String kdf,
    int memoryKib,
    int iterations,
    int parallelism,
  });

  Future<void> putVerifier(String verifier);

  /// `force` accepts that existing encrypted files become unreadable. It
  /// deletes nothing.
  Future<void> disable({bool force = false});
}

class ApiEncryptionRepository implements EncryptionRepository {
  ApiEncryptionRepository(this._api);

  final ApiClient _api;

  @override
  Future<EncryptionStatus> status() async {
    try {
      final data = await _api.get<Map<String, dynamic>>(
        '/encryption',
        parse: (d) => d as Map<String, dynamic>,
      );

      final enabled = data['enabled'] as bool? ?? data['salt'] != null;
      return EncryptionStatus(
        enabled: enabled,
        params: data['salt'] == null ? null : VaultParams.fromJson(data),
        verifier: data['verifier'] as String?,
      );
    } on ApiException catch (e) {
      // Never set up is a 404 here, and before setup that is the normal state.
      if (e.statusCode == 404) return const EncryptionStatus(enabled: false);
      rethrow;
    }
  }

  @override
  Future<VaultParams> enable({
    String kdf = 'argon2id',
    int memoryKib = 65536,
    int iterations = 3,
    int parallelism = 1,
  }) async {
    final data = await _api.post<Map<String, dynamic>>(
      '/encryption',
      body: {
        'kdf': kdf,
        'kdf_params': kdf == 'pbkdf2-sha256'
            ? {'iterations': iterations}
            : {
                'memory_kib': memoryKib,
                'iterations': iterations,
                'parallelism': parallelism,
              },
      },
      parse: (d) => d as Map<String, dynamic>,
    );

    // The salt is minted server-side; the key must come from the one returned,
    // not from anything chosen here.
    return VaultParams(
      salt: Uint8List.fromList(base64Decode(data['salt'] as String)),
      kdf: data['kdf'] as String? ?? kdf,
      memoryKib: memoryKib,
      iterations: iterations,
      parallelism: parallelism,
    );
  }

  @override
  Future<void> putVerifier(String verifier) =>
      _api.put<dynamic>('/encryption/verifier', body: {'verifier': verifier});

  @override
  Future<void> disable({bool force = false}) =>
      _api.delete<dynamic>('/encryption', query: {if (force) 'force': true});
}
