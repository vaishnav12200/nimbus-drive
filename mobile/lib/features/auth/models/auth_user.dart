/// The signed-in account, from `GET /auth/me`.
class AuthUser {
  const AuthUser({
    required this.id,
    required this.email,
    required this.encryptionEnabled,
    required this.hasPassword,
    required this.linkedProviders,
    this.displayName,
    this.lastLoginAt,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) => AuthUser(
    id: json['id'] as String,
    email: json['email'] as String,
    displayName: json['display_name'] as String?,
    encryptionEnabled: json['encryption_enabled'] as bool? ?? false,
    hasPassword: json['has_password'] as bool? ?? false,
    linkedProviders: [
      for (final p in json['linked_providers'] as List<dynamic>? ?? const [])
        '$p',
    ],
    lastLoginAt: DateTime.tryParse('${json['last_login_at']}')?.toLocal(),
  );

  final String id;
  final String email;
  final String? displayName;

  /// Whether client-side encryption has been set up. The key itself never
  /// leaves the device, so this only says a salt exists server-side.
  final bool encryptionEnabled;

  /// False for an account created purely through Google or GitHub. Such an
  /// account cannot be asked for its "current password".
  final bool hasPassword;

  final List<String> linkedProviders;
  final DateTime? lastLoginAt;

  /// Falls back to the local part of the email, so a display name is never
  /// empty on screen.
  String get name {
    final trimmed = displayName?.trim();
    if (trimmed != null && trimmed.isNotEmpty) return trimmed;
    return email.split('@').first;
  }
}

/// A live refresh-token session, from `GET /auth/sessions`.
class AuthSession {
  const AuthSession({
    required this.id,
    required this.issuedAt,
    required this.expiresAt,
    required this.isCurrent,
    this.userAgent,
    this.ipAddress,
  });

  factory AuthSession.fromJson(Map<String, dynamic> json) => AuthSession(
    id: json['id'] as String,
    issuedAt:
        DateTime.tryParse('${json['issued_at']}')?.toLocal() ?? DateTime.now(),
    expiresAt:
        DateTime.tryParse('${json['expires_at']}')?.toLocal() ?? DateTime.now(),
    isCurrent: json['current'] as bool? ?? false,
    userAgent: json['user_agent'] as String?,
    ipAddress: json['ip_address'] as String?,
  );

  final String id;
  final DateTime issuedAt;
  final DateTime expiresAt;

  /// The session making the request. It has no per-row revoke: signing itself
  /// out is what "sign out" means.
  final bool isCurrent;

  final String? userAgent;
  final String? ipAddress;

  /// A user agent is not a device name, but it is what the server has. Pulling
  /// the platform token out of it beats showing the whole string.
  String get device {
    final ua = userAgent;
    if (ua == null || ua.isEmpty) return 'Unknown device';

    for (final (needle, label) in const [
      ('Android', 'Android'),
      ('iPhone', 'iPhone'),
      ('iPad', 'iPad'),
      ('Macintosh', 'Mac'),
      ('Windows', 'Windows'),
      ('Linux', 'Linux'),
    ]) {
      if (ua.contains(needle)) return label;
    }
    return ua.length > 40 ? '${ua.substring(0, 40)}…' : ua;
  }
}
