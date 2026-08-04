import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nimbus_drive/core/crypto/vault_envelope.dart';
import 'package:nimbus_drive/core/crypto/vault_key.dart';

/// Cheap parameters. The KDF's cost is the point in production and pure noise
/// in a test — these exercise the same code path in milliseconds.
final _params = VaultParams(
  salt: Uint8List.fromList(List.generate(32, (i) => i)),
  memoryKib: 1024,
  iterations: 1,
);

Uint8List _bytes(int length, [int seed = 1]) {
  final random = Random(seed);
  return Uint8List.fromList(List.generate(length, (_) => random.nextInt(256)));
}

void main() {
  group('envelope arithmetic', () {
    test('chunk count rounds up, and zero bytes means zero chunks', () {
      expect(VaultEnvelope.chunkCountFor(0, 1024), 0);
      expect(VaultEnvelope.chunkCountFor(1, 1024), 1);
      expect(VaultEnvelope.chunkCountFor(1024, 1024), 1);
      expect(VaultEnvelope.chunkCountFor(1025, 1024), 2);
    });

    test('encrypted length is known before encrypting', () {
      // `POST /files/reserve` needs the size up front, so this has to be exact
      // rather than an estimate.
      const plain = 10 * 1024;
      const chunkSize = 4096;
      final expected = VaultEnvelope.encryptedLengthFor(
        plain,
        chunkSize: chunkSize,
      );

      final chunks = VaultEnvelope.chunkCountFor(plain, chunkSize);
      expect(
        expected,
        VaultEnvelope.headerBytesFor(chunks) +
            plain +
            chunks * VaultEnvelope.tagBytes,
      );
    });

    test('chunk offsets are arithmetic, not a lookup', () {
      const chunkSize = 4096;
      const count = 3;
      final first = VaultEnvelope.chunkOffset(
        0,
        chunkCount: count,
        chunkSize: chunkSize,
      );
      final second = VaultEnvelope.chunkOffset(
        1,
        chunkCount: count,
        chunkSize: chunkSize,
      );

      expect(first, VaultEnvelope.headerBytesFor(count));
      expect(second - first, chunkSize + VaultEnvelope.tagBytes);
    });

    test('maps a plaintext offset onto the chunk holding it', () {
      expect(VaultEnvelope.chunkForOffset(0, 1024), 0);
      expect(VaultEnvelope.chunkForOffset(1023, 1024), 0);
      expect(VaultEnvelope.chunkForOffset(1024, 1024), 1);
    });
  });

  group('round trip', () {
    test('seals and opens a file smaller than one chunk', () async {
      final key = await VaultKey.derive('correct-horse', _params);
      final plain = _bytes(500);

      final sealed = await key.seal(plain, chunkSize: 4096);
      expect(await key.open(sealed), plain);
    });

    test('seals and opens a file spanning several chunks', () async {
      final key = await VaultKey.derive('correct-horse', _params);
      // Deliberately not a multiple of the chunk size, so the last chunk is
      // short — the case an off-by-one in the arithmetic would break.
      final plain = _bytes(4096 * 3 + 137);

      final sealed = await key.seal(plain, chunkSize: 4096);
      expect(await key.open(sealed), plain);
    });

    test('an empty file round-trips', () async {
      final key = await VaultKey.derive('correct-horse', _params);
      final sealed = await key.seal(Uint8List(0));
      expect(await key.open(sealed), isEmpty);
    });

    test('the declared size matches what sealing actually produces', () async {
      final key = await VaultKey.derive('correct-horse', _params);
      final plain = _bytes(4096 * 2 + 7);

      final sealed = await key.seal(plain, chunkSize: 4096);
      expect(
        sealed.length,
        VaultEnvelope.encryptedLengthFor(plain.length, chunkSize: 4096),
      );
    });
  });

  group('seeking', () {
    test('one chunk decrypts without the rest of the file', () async {
      final key = await VaultKey.derive('correct-horse', _params);
      final plain = _bytes(4096 * 4);
      final sealed = await key.seal(plain, chunkSize: 4096);

      final header = VaultHeader.parse(sealed);
      const wanted = 2;

      // Exactly the span a Range request would ask the server for.
      final start = header.ciphertextOffsetOfChunk(wanted);
      final slice = Uint8List.sublistView(
        sealed,
        start,
        start + header.ciphertextLengthOfChunk(wanted),
      );

      final decrypted = await key.openChunk(
        slice,
        header: header,
        index: wanted,
      );
      expect(
        decrypted,
        Uint8List.sublistView(plain, 4096 * wanted, 4096 * (wanted + 1)),
      );
    });

    test('the header alone is enough to plan a fetch', () async {
      final key = await VaultKey.derive('correct-horse', _params);
      final sealed = await key.seal(_bytes(4096 * 3), chunkSize: 4096);

      // Parsed from the first bytes only — the client reads this, then decides
      // what to download.
      final prefix = Uint8List.sublistView(sealed, 0, 22 + 3 * 12);
      final header = VaultHeader.parse(prefix);

      expect(header.chunkCount, 3);
      expect(header.chunkSize, 4096);
      expect(header.plainLength, 4096 * 3);
    });
  });

  group('tamper resistance', () {
    test('a wrong password fails to open', () async {
      final right = await VaultKey.derive('correct-horse', _params);
      final wrong = await VaultKey.derive('battery-staple', _params);

      final sealed = await right.seal(_bytes(1000), chunkSize: 4096);
      await expectLater(wrong.open(sealed), throwsA(isA<VaultAuthException>()));
    });

    test('flipping a ciphertext byte is detected', () async {
      final key = await VaultKey.derive('correct-horse', _params);
      final sealed = await key.seal(_bytes(1000), chunkSize: 4096);

      sealed[sealed.length - 20] ^= 0xFF;
      await expectLater(key.open(sealed), throwsA(isA<VaultAuthException>()));
    });

    test('swapping two chunks is detected', () async {
      final key = await VaultKey.derive('correct-horse', _params);
      final plain = _bytes(4096 * 2);
      final sealed = await key.seal(plain, chunkSize: 4096);

      final header = VaultHeader.parse(sealed);
      final a = header.ciphertextOffsetOfChunk(0);
      final b = header.ciphertextOffsetOfChunk(1);
      final width = header.ciphertextLengthOfChunk(0);

      final first = Uint8List.fromList(
        Uint8List.sublistView(sealed, a, a + width),
      );
      sealed.setRange(
        a,
        a + width,
        Uint8List.sublistView(sealed, b, b + width),
      );
      sealed.setRange(b, b + width, first);

      // The chunk index is authenticated as AAD, so a reordered chunk fails its
      // tag instead of decrypting into the wrong place.
      await expectLater(key.open(sealed), throwsA(isA<VaultAuthException>()));
    });

    test('a foreign blob is rejected by its magic', () async {
      expect(
        () =>
            VaultHeader.parse(Uint8List.fromList(utf8.encode('not nimbus!!'))),
        throwsA(isA<VaultFormatException>()),
      );
    });

    test('a truncated header is rejected', () {
      expect(
        () => VaultHeader.parse(Uint8List(8)),
        throwsA(isA<VaultFormatException>()),
      );
    });
  });

  group('verifier', () {
    test('the right password matches, a wrong one does not', () async {
      final key = await VaultKey.derive('correct-horse', _params);
      final verifier = await key.buildVerifier();

      expect(await key.matches(verifier), isTrue);

      final wrong = await VaultKey.derive('battery-staple', _params);
      expect(await wrong.matches(verifier), isFalse);
    });

    test('is long enough for the server to accept', () async {
      final key = await VaultKey.derive('correct-horse', _params);
      final raw = base64Decode(await key.buildVerifier());

      // The API rejects anything at or under IV + tag as too short to be real.
      expect(raw.length, greaterThan(VaultEnvelope.ivBytes + 16));
    });
  });
}
