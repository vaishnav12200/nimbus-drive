/// The signed-in user and the state of everything the app needs configured.
///
/// One object because the Settings screen shows them together and they arrive
/// together — `/auth/me`, `/telegram/config` and `/encryption` are three calls
/// whose results are meaningless apart on this screen.
class Account {
  const Account({
    required this.displayName,
    required this.email,
    required this.storageUsed,
    required this.storageQuota,
    required this.telegram,
    required this.encryption,
    required this.sessions,
  });

  final String displayName;
  final String email;
  final int storageUsed;
  final int storageQuota;
  final TelegramBinding telegram;
  final EncryptionState encryption;
  final List<Session> sessions;

  int get activeSessions => sessions.length;

  double get storageFraction =>
      storageQuota == 0 ? 0 : (storageUsed / storageQuota).clamp(0.0, 1.0);
}

/// The bound channel that actually holds the bytes.
///
/// Without this the app cannot store anything, so an unbound account is not a
/// missing preference — it is a broken install, and the screen says so.
class TelegramBinding {
  const TelegramBinding({
    this.channelName,
    this.channelId,
    this.maskedBotToken,
    this.lastTestedAt,
    this.isActive = false,
  });

  final String? channelName;

  /// Always negative for a channel; a positive value is a pasted user id and
  /// the backend rejects it.
  final int? channelId;

  /// The server never returns the token in full, so neither does this.
  final String? maskedBotToken;

  final DateTime? lastTestedAt;
  final bool isActive;

  bool get isBound => isActive && channelId != null;
}

/// One live login, from `GET /auth/sessions`.
class Session {
  const Session({
    required this.id,
    required this.device,
    required this.lastSeen,
    this.location,
    this.isCurrent = false,
  });

  final String id;
  final String device;
  final DateTime lastSeen;
  final String? location;

  /// The session doing the asking. It cannot be signed out on its own —
  /// that is what "sign out" does — so its row carries no revoke action.
  final bool isCurrent;
}

/// Client-side encryption, which the server can describe but never undo.
class EncryptionState {
  const EncryptionState({
    this.enabled = false,
    this.kdf = 'argon2id',
    this.encryptedFileCount = 0,
  });

  final bool enabled;
  final String kdf;
  final int encryptedFileCount;
}
