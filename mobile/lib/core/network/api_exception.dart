/// The failure envelope, as `docs/API.md` defines it.
///
/// Every route answers `{success: false, error: {code, message, details}}`, and
/// the docs are explicit: **switch on `code`, never on `message`** — messages
/// are written for humans and will change.
class ApiException implements Exception {
  const ApiException({
    required this.code,
    required this.message,
    this.details,
    this.statusCode,
    this.requestId,
  });

  /// A transport failure, before any envelope existed.
  const ApiException.network(this.message)
    : code = ApiErrorCode.network,
      details = null,
      statusCode = null,
      requestId = null;

  final String code;

  /// Safe to show. The server writes these for display.
  final String message;

  final Map<String, dynamic>? details;
  final int? statusCode;

  /// `X-Request-ID`. Quote it in a bug report and it matches a server log line.
  final String? requestId;

  /// Per-field messages from a 422, keyed by field name.
  ///
  /// The server sends `details.fields: [{field, message, type}]`; forms want a
  /// map, so the shape is converted once here rather than in every screen.
  Map<String, String> get fieldErrors {
    final fields = details?['fields'];
    if (fields is! List) return const {};

    return {
      for (final entry in fields)
        if (entry is Map && entry['field'] != null)
          '${entry['field']}': '${entry['message'] ?? 'Invalid'}',
    };
  }

  /// Seconds to wait, from `RATE_LIMITED` and `FLOOD_WAIT`.
  int? get retryAfter {
    final value = details?['retry_after'];
    return value is num ? value.toInt() : null;
  }

  bool get isAuthFailure =>
      code == ApiErrorCode.invalidToken ||
      code == ApiErrorCode.tokenReuseDetected;

  /// The session is unrecoverable and the user must sign in again.
  ///
  /// Reuse means either theft or a client bug, and the server has already
  /// revoked every session descended from that login — including the one that
  /// legitimately rotated.
  bool get requiresReauth => code == ApiErrorCode.tokenReuseDetected;

  @override
  String toString() => message;
}

/// Error codes this client reacts to.
///
/// Plain strings rather than an enum: the server may add a code before the app
/// is rebuilt, and an unknown code must fall through to "show the message"
/// rather than fail to parse.
abstract final class ApiErrorCode {
  static const validation = 'VALIDATION_ERROR';
  static const invalidCredentials = 'INVALID_CREDENTIALS';
  static const invalidToken = 'INVALID_TOKEN';
  static const tokenReuseDetected = 'TOKEN_REUSE_DETECTED';
  static const permissionDenied = 'PERMISSION_DENIED';
  static const fileNotFound = 'FILE_NOT_FOUND';
  static const folderNotFound = 'FOLDER_NOT_FOUND';
  static const telegramNotConfigured = 'TELEGRAM_NOT_CONFIGURED';
  static const folderNotEmpty = 'FOLDER_NOT_EMPTY';
  static const cannotShareEncrypted = 'CANNOT_SHARE_ENCRYPTED';
  static const shareExpired = 'SHARE_EXPIRED';
  static const rateLimited = 'RATE_LIMITED';
  static const floodWait = 'FLOOD_WAIT';
  static const useBackendUpload = 'USE_BACKEND_UPLOAD';
  static const uploadCapacity = 'UPLOAD_CAPACITY';

  /// Client-side only: no response was received at all.
  static const network = 'NETWORK_ERROR';
}
