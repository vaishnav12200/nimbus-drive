import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/utils/formatters.dart';
import 'data/auth_repository.dart';
import 'models/auth_user.dart';

enum AuthStatus {
  /// Deciding whether a stored session is still good. The splash sits here.
  restoring,
  signedOut,
  signedIn,
}

/// Who is signed in, and the only place that changes.
///
/// The app shell listens to this rather than to any screen, so a session lost
/// mid-request — a revoked token, a detected replay — drops the user back to
/// sign-in from wherever they were.
class AuthController extends ChangeNotifier {
  AuthController(this._repository, {ApiClient? client}) {
    _lost = client?.onSessionLost.listen(_onSessionLost);
    restore();
  }

  final AuthRepository _repository;
  StreamSubscription<ApiException>? _lost;

  AuthStatus _status = AuthStatus.restoring;
  AuthUser? _user;
  bool _busy = false;
  String? _error;

  /// Set when the session ended on its own rather than by the user's choice,
  /// so sign-in can explain why they are looking at it again.
  String? _endedReason;

  AuthStatus get status => _status;
  AuthUser? get user => _user;
  bool get busy => _busy;
  String? get error => _error;
  String? get endedReason => _endedReason;

  /// Per-field messages from a 422, for showing errors under the right input.
  Map<String, String> fieldErrors = const {};

  /// Drops a failure from a previous screen.
  ///
  /// The controller outlives the sign-in and register screens, so without this
  /// a rejected sign-in still shows its error after navigating to register —
  /// where it is about a form the user has not submitted yet.
  void clearError() {
    if (_error == null && fieldErrors.isEmpty) return;
    _error = null;
    fieldErrors = const {};
    notifyListeners();
  }

  Future<void> restore() async {
    _status = AuthStatus.restoring;
    notifyListeners();

    final user = await _repository.restore();
    _user = user;
    _status = user == null ? AuthStatus.signedOut : AuthStatus.signedIn;
    notifyListeners();
  }

  Future<bool> signIn({required String email, required String password}) =>
      _run(() => _repository.signIn(email: email.trim(), password: password));

  Future<bool> register({
    required String email,
    required String password,
    String? displayName,
  }) => _run(
    () => _repository.register(
      email: email.trim(),
      password: password,
      displayName: displayName,
    ),
  );

  /// Shared submit path: one busy flag, one error slot, one success route.
  Future<bool> _run(Future<AuthUser> Function() action) async {
    _busy = true;
    _error = null;
    fieldErrors = const {};
    notifyListeners();

    try {
      _user = await action();
      _status = AuthStatus.signedIn;
      _endedReason = null;
      return true;
    } on ApiException catch (e) {
      _error = _describe(e);
      fieldErrors = e.fieldErrors;
      return false;
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  /// The server's message, with the wait appended when there is one.
  ///
  /// Registration is capped at 5 per hour per IP and login at 10 per 5 minutes,
  /// both of which are easy to hit while developing. "Too many requests; slow
  /// down" on its own does not tell anyone how long to slow down for.
  static String _describe(ApiException e) {
    final wait = e.retryAfter;
    if (wait == null || wait <= 0) return e.message;
    return '${e.message}. Try again in ${formatRetryAfter(wait)}.';
  }

  Future<void> signOut() async {
    await _repository.signOut();
    _finish();
  }

  Future<void> signOutEverywhere() async {
    await _repository.signOutEverywhere();
    _finish();
  }

  Future<List<AuthSession>> sessions() => _repository.sessions();

  void _finish() {
    _user = null;
    _status = AuthStatus.signedOut;
    _endedReason = null;
    notifyListeners();
  }

  /// The client could not refresh. Reuse revokes every session in the family,
  /// so the only correct response is to discard everything and re-authenticate.
  void _onSessionLost(ApiException e) {
    if (_status == AuthStatus.signedOut) return;

    _user = null;
    _status = AuthStatus.signedOut;
    _endedReason = e.requiresReauth
        ? 'Your session was ended for security. Please sign in again.'
        : 'Your session expired. Please sign in again.';
    notifyListeners();
  }

  @override
  void dispose() {
    _lost?.cancel();
    super.dispose();
  }
}
