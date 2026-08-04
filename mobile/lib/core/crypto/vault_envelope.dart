import 'dart:typed_data';

/// The on-disk layout of an encrypted file.
///
/// ## Why a format at all
///
/// AES-256-GCM authenticates a whole message: you cannot verify the tag without
/// every byte, and you cannot decrypt from an arbitrary offset. Encrypting a
/// file as one blob therefore means a 1 GB video must be downloaded and
/// decrypted in full before the first frame — no seeking, ever.
///
/// The fix is to encrypt in independent chunks, each with its own IV. The
/// obvious place for those IVs is the `file_chunks` table, but it has no column
/// for them and the *server* does the chunking, so the client never sees those
/// boundaries. Changing that would mean a migration and a new upload contract.
///
/// Instead the ciphertext describes itself. The client picks its own chunk
/// size, writes a header listing every IV, and appends the encrypted chunks.
/// The server stores the result as opaque bytes and chunks it for transport
/// however it likes — the two layers do not need to agree. Seeking works
/// through the `Range` support that already exists: read the header, compute
/// where a chunk lives, fetch exactly that span.
///
/// ## Layout
///
/// ```
/// magic        4  bytes  "NBE1"
/// version      1  byte
/// flags        1  byte   reserved, must be 0
/// chunkSize    4  bytes  big-endian, plaintext bytes per chunk
/// chunkCount   4  bytes  big-endian
/// plainLength  8  bytes  big-endian, total plaintext length
/// ivs         12 * chunkCount bytes
/// -- then, back to back --
/// chunk 0      chunkSize + 16 bytes  (ciphertext + GCM tag)
/// chunk 1      ...
/// chunk n-1    remainder + 16
/// ```
///
/// Every chunk but the last holds exactly [chunkSize] plaintext bytes, so the
/// offset of any chunk is arithmetic rather than a lookup.
abstract final class VaultEnvelope {
  static const List<int> magic = [0x4E, 0x42, 0x45, 0x31]; // "NBE1"
  static const int version = 1;

  /// AES-GCM's standard nonce. The backend pins the same value — anything but
  /// 12 forces libraries into an extra derivation and interoperates badly.
  static const int ivBytes = 12;

  /// GCM authentication tag, appended to each chunk's ciphertext.
  static const int tagBytes = 16;

  /// Plaintext bytes per chunk.
  ///
  /// The trade is seek granularity against header size. At 4 MiB, starting
  /// playback at an arbitrary point costs at most 4 MiB of download, and a 2 GB
  /// file needs 512 IVs — a 6 KB header. Smaller chunks seek finer but the
  /// header grows linearly and is fetched before anything else can happen.
  static const int defaultChunkSize = 4 * 1024 * 1024;

  static const int _fixedHeaderBytes = 4 + 1 + 1 + 4 + 4 + 8;

  static int headerBytesFor(int chunkCount) =>
      _fixedHeaderBytes + chunkCount * ivBytes;

  static int chunkCountFor(int plainLength, int chunkSize) =>
      plainLength == 0 ? 0 : (plainLength + chunkSize - 1) ~/ chunkSize;

  /// Total size of the encrypted blob for a plaintext of [plainLength].
  ///
  /// Known before a byte is encrypted, which is what lets an upload declare its
  /// size up front — `POST /files/reserve` requires one.
  static int encryptedLengthFor(
    int plainLength, {
    int chunkSize = defaultChunkSize,
  }) {
    final chunks = chunkCountFor(plainLength, chunkSize);
    return headerBytesFor(chunks) + plainLength + chunks * tagBytes;
  }

  /// Where chunk [index]'s ciphertext starts within the blob.
  static int chunkOffset(
    int index, {
    required int chunkCount,
    required int chunkSize,
  }) => headerBytesFor(chunkCount) + index * (chunkSize + tagBytes);

  /// Which chunk holds plaintext byte [offset].
  static int chunkForOffset(int offset, int chunkSize) => offset ~/ chunkSize;
}

/// The parsed header of an encrypted blob.
class VaultHeader {
  const VaultHeader({
    required this.chunkSize,
    required this.chunkCount,
    required this.plainLength,
    required this.ivs,
  });

  final int chunkSize;
  final int chunkCount;
  final int plainLength;

  /// One IV per chunk, in order.
  final List<Uint8List> ivs;

  int get headerLength => VaultEnvelope.headerBytesFor(chunkCount);

  /// Plaintext length of chunk [index] — the last one is usually short.
  int plainLengthOfChunk(int index) {
    if (index < chunkCount - 1) return chunkSize;
    final remainder = plainLength - (chunkCount - 1) * chunkSize;
    return remainder;
  }

  int ciphertextOffsetOfChunk(int index) => VaultEnvelope.chunkOffset(
    index,
    chunkCount: chunkCount,
    chunkSize: chunkSize,
  );

  int ciphertextLengthOfChunk(int index) =>
      plainLengthOfChunk(index) + VaultEnvelope.tagBytes;

  Uint8List toBytes() {
    final out = Uint8List(headerLength);
    final view = ByteData.view(out.buffer);

    out.setRange(0, 4, VaultEnvelope.magic);
    out[4] = VaultEnvelope.version;
    out[5] = 0; // flags
    view.setUint32(6, chunkSize);
    view.setUint32(10, chunkCount);
    view.setUint64(14, plainLength);

    var at = 22;
    for (final iv in ivs) {
      out.setRange(at, at + VaultEnvelope.ivBytes, iv);
      at += VaultEnvelope.ivBytes;
    }
    return out;
  }

  /// Reads a header from the first bytes of a blob.
  ///
  /// Throws [VaultFormatException] rather than returning null: a file that
  /// claims to be encrypted and is not parseable is a bug or a corrupted
  /// download, and silently treating it as plaintext would be worse.
  static VaultHeader parse(Uint8List bytes) {
    if (bytes.length < 22) {
      throw const VaultFormatException('Encrypted header is truncated');
    }
    for (var i = 0; i < 4; i++) {
      if (bytes[i] != VaultEnvelope.magic[i]) {
        throw const VaultFormatException('Not a Nimbus encrypted file');
      }
    }
    if (bytes[4] != VaultEnvelope.version) {
      throw VaultFormatException(
        'Encrypted with a newer version of Nimbus (v${bytes[4]})',
      );
    }

    final view = ByteData.view(bytes.buffer, bytes.offsetInBytes);
    final chunkSize = view.getUint32(6);
    final chunkCount = view.getUint32(10);
    final plainLength = view.getUint64(14);

    if (chunkSize <= 0) {
      throw const VaultFormatException('Encrypted header declares no chunks');
    }

    final needed = VaultEnvelope.headerBytesFor(chunkCount);
    if (bytes.length < needed) {
      throw const VaultFormatException('Encrypted header is truncated');
    }

    final ivs = <Uint8List>[];
    for (var i = 0; i < chunkCount; i++) {
      final at = 22 + i * VaultEnvelope.ivBytes;
      ivs.add(Uint8List.sublistView(bytes, at, at + VaultEnvelope.ivBytes));
    }

    return VaultHeader(
      chunkSize: chunkSize,
      chunkCount: chunkCount,
      plainLength: plainLength,
      ivs: ivs,
    );
  }
}

class VaultFormatException implements Exception {
  const VaultFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Wrong password, or tampered ciphertext. The two are indistinguishable to
/// GCM, and telling them apart is not the client's job.
class VaultAuthException implements Exception {
  const VaultAuthException([
    this.message = 'Could not decrypt — wrong password, or the file is damaged',
  ]);

  final String message;

  @override
  String toString() => message;
}
