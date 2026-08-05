// ignore_for_file: avoid_print — this is a diagnostic tool, not app code.
//
// Needs a real backend on 127.0.0.1:8000. Run it deliberately:
//
//   flutter test test/live_encryption_check.dart
//
// Verifies the encryption contract against the *server* rather than against a
// mock: that the salt it mints derives a working key, that the verifier it
// stores round-trips, and that a sealed blob survives being handed back.
import 'package:flutter_test/flutter_test.dart';
import 'package:nimbus_drive/core/crypto/vault_envelope.dart';
import 'package:nimbus_drive/core/crypto/vault_key.dart';
import 'package:nimbus_drive/core/network/api_client.dart';
import 'package:nimbus_drive/core/network/token_store.dart';
import 'package:nimbus_drive/features/auth/data/auth_repository.dart';
import 'package:nimbus_drive/features/encryption/data/encryption_repository.dart';

import 'dart:math';
import 'dart:typed_data';

Uint8List _bytes(int length) {
  final random = Random(42);
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

/// Target host. Defaults to a local dev server; point it at the deployed one
/// with `--dart-define=NIMBUS_API_BASE=https://<host>/api`.
const _baseUrl = String.fromEnvironment(
  'NIMBUS_API_BASE',
  defaultValue: 'http://127.0.0.1:8000/api',
);

void main() {
  test('encryption round-trips against the live API', () async {
    final tokens = InMemoryTokenStore();
    final api = ApiClient(tokens, baseUrl: _baseUrl);
    final auth = ApiAuthRepository(api, tokens);
    final vault = ApiEncryptionRepository(api);

    final email =
        'enc${DateTime.now().millisecondsSinceEpoch}@nimbus.example.com';
    await auth.register(
      email: email,
      password: 'correct-horse-battery',
      displayName: 'Enc Check',
    );
    print('register    -> $email');

    // Before setup the account reports encryption off.
    var status = await vault.status();
    expect(status.enabled, isFalse);
    print('status      -> off, as expected');

    // The server mints the salt; the key must come from that, not from
    // anything chosen locally.
    final params = await vault.enable();
    expect(params.salt.length, 32);
    print(
      'enable      -> salt=${params.salt.length}B kdf=${params.kdf} '
      'm=${params.memoryKib} t=${params.iterations}',
    );

    final key = await VaultKey.derive('a-very-long-vault-password', params);
    final verifier = await key.buildVerifier();
    await vault.putVerifier(verifier);
    print('verifier    -> stored (${verifier.length} b64 chars)');

    // A second device reads the params back and re-derives.
    status = await vault.status();
    expect(status.enabled, isTrue);
    expect(status.params, isNotNull);
    expect(status.verifier, isNotNull);

    final reDerived = await VaultKey.derive(
      'a-very-long-vault-password',
      status.params!,
    );
    expect(await reDerived.matches(status.verifier!), isTrue);
    print('re-derive   -> verifier matches on a "second device"');

    final wrong = await VaultKey.derive('the-wrong-password', status.params!);
    expect(await wrong.matches(status.verifier!), isFalse);
    print('wrong pass  -> rejected without downloading anything');

    // The payload a real upload would send, sealed with the same key.
    final plain = _bytes(VaultEnvelope.defaultChunkSize + 4096);
    final sealed = await key.seal(plain);
    expect(
      sealed.length,
      VaultEnvelope.encryptedLengthFor(plain.length),
      reason: 'reserve declares this size before sealing',
    );
    print(
      'seal        -> ${plain.length}B plain -> ${sealed.length}B sealed '
      '(${VaultHeader.parse(sealed).chunkCount} chunks)',
    );

    expect(await reDerived.open(sealed), plain);
    print('open        -> byte-identical after a full round trip');

    // The seek path: one chunk, decrypted from its byte range alone.
    final header = VaultHeader.parse(sealed);
    final start = header.ciphertextOffsetOfChunk(1);
    final slice = Uint8List.sublistView(
      sealed,
      start,
      start + header.ciphertextLengthOfChunk(1),
    );
    final chunk = await reDerived.openChunk(slice, header: header, index: 1);
    expect(chunk, Uint8List.sublistView(plain, header.chunkSize, plain.length));
    print('seek        -> chunk 1 decrypted from its range alone');

    // Disabling with no encrypted files is allowed; the guard is about files.
    await vault.disable();
    expect((await vault.status()).enabled, isFalse);
    print('disable     -> back to off');
  });
}
