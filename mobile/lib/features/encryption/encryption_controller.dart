import 'package:flutter/foundation.dart';

import '../../core/crypto/vault_key.dart';
import '../../core/network/api_exception.dart';
import 'data/encryption_repository.dart';

enum VaultState {
  /// Still asking the server.
  loading,

  /// Encryption has never been set up on this account.
  off,

  /// Set up, but this device has no key — the password is needed.
  locked,

  /// Key derived and held in memory.
  unlocked,
}

/// Owns the derived key for the lifetime of the process.
///
/// The key is never written anywhere and the password is never sent. Losing the
/// password means the data is unrecoverable, which the setup screen states in
/// as many words — it is the design, not an oversight.
class EncryptionController extends ChangeNotifier {
  EncryptionController(this._repository) {
    refresh();
  }

  final EncryptionRepository _repository;

  VaultState _state = VaultState.loading;
  EncryptionStatus? _status;
  VaultKey? _key;
  bool _busy = false;
  String? _error;

  VaultState get state => _state;
  bool get busy => _busy;
  String? get error => _error;

  /// Whether uploads should encrypt. Only true with a key in hand — offering
  /// encryption while locked would produce files nothing can open.
  bool get canEncrypt => _state == VaultState.unlocked;

  bool get isSetUp => _state != VaultState.off && _state != VaultState.loading;

  /// The key, or null. Held by the upload engine for the session.
  VaultKey? get key => _key;

  Future<void> refresh() async {
    _state = VaultState.loading;
    notifyListeners();

    try {
      _status = await _repository.status();
      // A key already derived this session survives a status refresh.
      _state = !_status!.enabled
          ? VaultState.off
          : (_key != null ? VaultState.unlocked : VaultState.locked);
    } on ApiException catch (e) {
      _error = e.message;
      _state = VaultState.off;
    }
    notifyListeners();
  }

  /// Turns encryption on and derives the key from [password].
  ///
  /// Enabling mints the salt server-side, so the key must be derived from what
  /// the server returns rather than from anything chosen here.
  Future<bool> setUp(String password) async {
    _busy = true;
    _error = null;
    notifyListeners();

    try {
      final params = await _repository.enable();
      final key = await VaultKey.derive(password, params);

      // Attached immediately so a second device can reject a wrong password
      // before downloading anything.
      await _repository.putVerifier(await key.buildVerifier());

      _key = key;
      _status = EncryptionStatus(enabled: true, params: params);
      _state = VaultState.unlocked;
      return true;
    } on ApiException catch (e) {
      _error = e.statusCode == 409
          ? 'Encryption is already set up on this account. Unlock it with your '
                'existing password instead.'
          : e.message;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Derives the key on a device that did not set it up.
  Future<bool> unlock(String password) async {
    final params = _status?.params;
    if (params == null) return false;

    _busy = true;
    _error = null;
    notifyListeners();

    try {
      final key = await VaultKey.derive(password, params);

      final verifier = _status?.verifier;
      if (verifier != null && !await key.matches(verifier)) {
        _error = 'That password does not match this account.';
        return false;
      }

      _key = key;
      _state = VaultState.unlocked;
      return true;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// Forgets the key without touching the account.
  ///
  /// Separate from disabling: locking is reversible with the password,
  /// disabling is a server-side change that can orphan files.
  void lock() {
    if (_key == null) return;
    _key = null;
    _state = VaultState.locked;
    notifyListeners();
  }

  @override
  void dispose() {
    _key = null;
    super.dispose();
  }
}
