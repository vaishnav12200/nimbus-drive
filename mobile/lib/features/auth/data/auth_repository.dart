import '../../../core/network/api_client.dart';
import '../../../core/network/token_store.dart';
import '../models/auth_user.dart';

abstract interface class AuthRepository {
  Future<AuthUser> register({
    required String email,
    required String password,
    String? displayName,
  });

  Future<AuthUser> signIn({required String email, required String password});

  /// The signed-in account, or null when there is no usable session.
  Future<AuthUser?> restore();

  Future<void> signOut();

  Future<void> signOutEverywhere();

  Future<List<AuthSession>> sessions();
}

class ApiAuthRepository implements AuthRepository {
  ApiAuthRepository(this._api, this._tokens);

  final ApiClient _api;
  final TokenStore _tokens;

  @override
  Future<AuthUser> register({
    required String email,
    required String password,
    String? displayName,
  }) async {
    await _authenticate('/auth/register', {
      'email': email,
      'password': password,
      if (displayName != null && displayName.trim().isNotEmpty)
        'display_name': displayName.trim(),
    });
    return _me();
  }

  @override
  Future<AuthUser> signIn({
    required String email,
    required String password,
  }) async {
    await _authenticate('/auth/login', {'email': email, 'password': password});
    return _me();
  }

  /// Stores the pair before returning, so a caller that throws afterwards
  /// cannot leave the app authenticated-but-tokenless.
  Future<void> _authenticate(String path, Map<String, dynamic> body) async {
    final data = await _api.post<Map<String, dynamic>>(
      path,
      body: body,
      // No token exists yet, and sending a stale one would 401 the login.
      skipAuth: true,
      parse: (d) => d as Map<String, dynamic>,
    );

    await _tokens.write(
      TokenPair(
        accessToken: data['access_token'] as String,
        refreshToken: data['refresh_token'] as String,
      ),
    );
  }

  Future<AuthUser> _me() => _api.get<AuthUser>(
    '/auth/me',
    parse: (d) => AuthUser.fromJson(d as Map<String, dynamic>),
  );

  @override
  Future<AuthUser?> restore() async {
    if (await _tokens.read() == null) return null;
    try {
      return await _me();
    } on Object {
      // The client already refreshes transparently, so a failure here means
      // the session is genuinely gone rather than merely stale.
      await _tokens.clear();
      return null;
    }
  }

  @override
  Future<void> signOut() async {
    final pair = await _tokens.read();
    try {
      await _api.post<dynamic>(
        '/auth/logout',
        body: {if (pair != null) 'refresh_token': pair.refreshToken},
      );
    } on Object {
      // Signing out must succeed locally regardless. A server that cannot be
      // reached is not a reason to leave the user looking signed in.
    }
    await _tokens.clear();
  }

  @override
  Future<void> signOutEverywhere() async {
    try {
      await _api.post<dynamic>('/auth/logout-all');
    } finally {
      await _tokens.clear();
    }
  }

  @override
  Future<List<AuthSession>> sessions() => _api.get<List<AuthSession>>(
    '/auth/sessions',
    parse: (d) => [
      for (final item in d as List<dynamic>)
        AuthSession.fromJson(item as Map<String, dynamic>),
    ],
  );
}
