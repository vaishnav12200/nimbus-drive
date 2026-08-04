import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'vault_envelope.dart';

/// The plaintext sealed into the verifier.
///
/// A new device decrypts this before fetching anything: if it comes back
/// intact, the password derived the same key, and a wrong password is rejected
/// in one round trip instead of after a download.
const String kVerifierPlaintext = 'nimbus-drive-verifier-v1';

/// The parameters needed to turn a password back into the same key.
///
/// All of it is public and all of it lives on the server — none of it is
/// secret, and none of it is enough to recover the key without the password.
class VaultParams {
  const VaultParams({
    required this.salt,
    this.kdf = 'argon2id',
    this.memoryKib = 65536,
    this.iterations = 3,
    this.parallelism = 1,
  });

  factory VaultParams.fromJson(Map<String, dynamic> json) {
    final params = json['kdf_params'] as Map<String, dynamic>? ?? const {};
    return VaultParams(
      salt: base64Decode(json['salt'] as String),
      kdf: json['kdf'] as String? ?? 'argon2id',
      memoryKib: (params['memory_kib'] as num?)?.toInt() ?? 65536,
      iterations: (params['iterations'] as num?)?.toInt() ?? 3,
      parallelism: (params['parallelism'] as num?)?.toInt() ?? 1,
    );
  }

  final Uint8List salt;
  final String kdf;
  final int memoryKib;
  final int iterations;
  final int parallelism;

  Map<String, int> get asRequestParams => kdf == 'pbkdf2-sha256'
      ? {'iterations': iterations}
      : {
          'memory_kib': memoryKib,
          'iterations': iterations,
          'parallelism': parallelism,
        };
}

/// A derived key, held only in memory.
///
/// The password is never stored and the key is never sent. Forgetting the
/// password means the data is unrecoverable — that is the design, not an
/// oversight, and the setup screen says so in as many words.
class VaultKey {
  VaultKey._(this._key);

  final SecretKey _key;

  static final _aes = AesGcm.with256bits(nonceLength: VaultEnvelope.ivBytes);

  /// Runs the KDF. Expensive on purpose — Argon2id at 64 MiB takes a noticeable
  /// moment on a mid-range phone, which is the point.
  static Future<VaultKey> derive(String password, VaultParams params) async {
    final KdfAlgorithm algorithm = params.kdf == 'pbkdf2-sha256'
        ? Pbkdf2(
            macAlgorithm: Hmac.sha256(),
            iterations: params.iterations,
            bits: 256,
          )
        : Argon2id(
            memory: params.memoryKib,
            iterations: params.iterations,
            parallelism: params.parallelism,
            hashLength: 32,
          );

    final key = await algorithm.deriveKeyFromPassword(
      password: password,
      nonce: params.salt,
    );
    return VaultKey._(key);
  }

  /// Seals [kVerifierPlaintext], IV prepended, base64 — the shape
  /// `PUT /api/encryption/verifier` documents.
  Future<String> buildVerifier() async {
    final box = await _aes.encrypt(
      utf8.encode(kVerifierPlaintext),
      secretKey: _key,
    );
    return base64Encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]);
  }

  /// Whether [verifier] was sealed under this key.
  ///
  /// Returns false rather than throwing: a wrong password is the expected
  /// outcome here, not an error.
  Future<bool> matches(String verifier) async {
    try {
      final raw = base64Decode(verifier);
      final plain = await _open(
        Uint8List.fromList(raw.sublist(VaultEnvelope.ivBytes)),
        Uint8List.fromList(raw.sublist(0, VaultEnvelope.ivBytes)),
        null,
      );
      return utf8.decode(plain) == kVerifierPlaintext;
    } on Object {
      return false;
    }
  }

  /// Encrypts [plaintext] into the self-describing envelope.
  Future<Uint8List> seal(
    Uint8List plaintext, {
    int chunkSize = VaultEnvelope.defaultChunkSize,
  }) async {
    final chunkCount = VaultEnvelope.chunkCountFor(plaintext.length, chunkSize);

    final ivs = <Uint8List>[];
    final chunks = <Uint8List>[];

    for (var i = 0; i < chunkCount; i++) {
      final start = i * chunkSize;
      final end = (start + chunkSize).clamp(0, plaintext.length);
      final slice = Uint8List.sublistView(plaintext, start, end);

      final box = await _aes.encrypt(
        slice,
        secretKey: _key,
        // The chunk index is authenticated but not encrypted, so a chunk moved
        // to another position fails its tag. Without this, ciphertext chunks
        // could be reordered or replayed undetected.
        aad: _aadFor(i),
      );

      ivs.add(Uint8List.fromList(box.nonce));
      chunks.add(Uint8List.fromList([...box.cipherText, ...box.mac.bytes]));
    }

    final header = VaultHeader(
      chunkSize: chunkSize,
      chunkCount: chunkCount,
      plainLength: plaintext.length,
      ivs: ivs,
    );

    final out = BytesBuilder(copy: false)..add(header.toBytes());
    for (final chunk in chunks) {
      out.add(chunk);
    }
    return out.takeBytes();
  }

  /// Decrypts a whole blob.
  Future<Uint8List> open(Uint8List blob) async {
    final header = VaultHeader.parse(blob);
    final out = BytesBuilder(copy: false);

    for (var i = 0; i < header.chunkCount; i++) {
      final start = header.ciphertextOffsetOfChunk(i);
      final end = start + header.ciphertextLengthOfChunk(i);
      if (end > blob.length) {
        throw const VaultFormatException('Encrypted file is truncated');
      }
      out.add(
        await openChunk(
          Uint8List.sublistView(blob, start, end),
          header: header,
          index: i,
        ),
      );
    }
    return out.takeBytes();
  }

  /// Decrypts one chunk, fetched on its own.
  ///
  /// This is what makes seeking work: the caller asks the server for exactly
  /// the byte range [VaultHeader.ciphertextOffsetOfChunk] describes and hands
  /// the result here, without ever holding the rest of the file.
  Future<Uint8List> openChunk(
    Uint8List ciphertextWithTag, {
    required VaultHeader header,
    required int index,
  }) => _open(ciphertextWithTag, header.ivs[index], _aadFor(index));

  Future<Uint8List> _open(
    Uint8List ciphertextWithTag,
    List<int> iv,
    List<int>? aad,
  ) async {
    if (ciphertextWithTag.length < VaultEnvelope.tagBytes) {
      throw const VaultFormatException('Encrypted chunk is truncated');
    }
    final split = ciphertextWithTag.length - VaultEnvelope.tagBytes;

    try {
      final plain = await _aes.decrypt(
        SecretBox(
          Uint8List.sublistView(ciphertextWithTag, 0, split),
          nonce: iv,
          mac: Mac(Uint8List.sublistView(ciphertextWithTag, split)),
        ),
        secretKey: _key,
        aad: aad ?? const [],
      );
      return Uint8List.fromList(plain);
    } on SecretBoxAuthenticationError {
      throw const VaultAuthException();
    }
  }

  /// `NBE1` followed by the chunk index, big-endian.
  static Uint8List _aadFor(int index) {
    final out = Uint8List(8);
    out.setRange(0, 4, VaultEnvelope.magic);
    ByteData.view(out.buffer).setUint32(4, index);
    return out;
  }
}
