import 'dart:async';

import 'package:dio/dio.dart';

import 'api_exception.dart';
import 'token_store.dart';

/// Where the backend lives.
///
/// Overridden at build time:
/// `flutter run --dart-define=NIMBUS_API_BASE=https://your-server/api`
///
/// The default targets a desktop dev server. `10.0.2.2` is how the Android
/// emulator reaches the host's loopback — `localhost` there is the emulator
/// itself, which is the first thing that goes wrong when wiring a client up.
abstract final class ApiConfig {
  static const String baseUrl = String.fromEnvironment(
    'NIMBUS_API_BASE',
    defaultValue: 'http://127.0.0.1:8000/api',
  );

  static const String androidEmulatorHost = 'http://10.0.2.2:8000/api';
}

/// Talks to the Nimbus backend.
///
/// Owns three things the rest of the app should never repeat: unwrapping the
/// success envelope, turning the failure envelope into [ApiException], and
/// refreshing an expired access token exactly once no matter how many requests
/// notice it has expired.
class ApiClient {
  ApiClient(this._tokens, {Dio? dio, String? baseUrl})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: baseUrl ?? ApiConfig.baseUrl,
              connectTimeout: const Duration(seconds: 15),
              // Generous: an upload or a proxied download can legitimately be
              // slow, and a short receive timeout would kill it mid-stream.
              receiveTimeout: const Duration(minutes: 5),
              sendTimeout: const Duration(minutes: 5),
              // Every status is "successful" so failures reach the envelope
              // parser instead of becoming a DioException with no code.
              validateStatus: (_) => true,
            ),
          ) {
    _dio.interceptors.add(
      InterceptorsWrapper(onRequest: _attachToken, onError: _onTransportError),
    );
  }

  final Dio _dio;
  final TokenStore _tokens;

  /// Fired when the session cannot be recovered and the user must sign in
  /// again — a failed refresh, or `TOKEN_REUSE_DETECTED`.
  final _sessionLost = StreamController<ApiException>.broadcast();

  Stream<ApiException> get onSessionLost => _sessionLost.stream;

  /// The in-flight refresh, if one is running.
  ///
  /// Single-flight matters more here than usual: refresh tokens are single-use,
  /// so two concurrent refreshes would consume the same token twice and the
  /// second would trip `TOKEN_REUSE_DETECTED` — logging the user out for
  /// nothing more than opening two screens at once.
  Future<TokenPair?>? _refreshing;

  Dio get raw => _dio;

  Future<void> _attachToken(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (options.extra['skipAuth'] != true) {
      final pair = await _tokens.read();
      if (pair != null) {
        options.headers['Authorization'] = 'Bearer ${pair.accessToken}';
      }
    }
    handler.next(options);
  }

  void _onTransportError(DioException e, ErrorInterceptorHandler handler) {
    // `validateStatus` swallows HTTP status errors, so anything arriving here
    // is a real transport failure: DNS, refused connection, timeout.
    handler.reject(
      DioException(
        requestOptions: e.requestOptions,
        error: ApiException.network(_describe(e)),
      ),
    );
  }

  static String _describe(DioException e) => switch (e.type) {
    DioExceptionType.connectionTimeout ||
    DioExceptionType.sendTimeout ||
    DioExceptionType.receiveTimeout => 'The server took too long to respond',
    DioExceptionType.connectionError =>
      'Could not reach the server. Check your connection.',
    _ => 'Network error',
  };

  // --- Verbs ----------------------------------------------------------------

  Future<T> get<T>(
    String path, {
    Map<String, dynamic>? query,
    T Function(dynamic data)? parse,
  }) => _send(path, 'GET', query: query, parse: parse);

  Future<T> post<T>(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    T Function(dynamic data)? parse,
    bool skipAuth = false,
  }) => _send(
    path,
    'POST',
    body: body,
    query: query,
    parse: parse,
    skipAuth: skipAuth,
  );

  Future<T> patch<T>(
    String path, {
    Object? body,
    T Function(dynamic data)? parse,
  }) => _send(path, 'PATCH', body: body, parse: parse);

  Future<T> delete<T>(
    String path, {
    Map<String, dynamic>? query,
    T Function(dynamic data)? parse,
  }) => _send(path, 'DELETE', query: query, parse: parse);

  /// Success payload plus the page meta, for endpoints that paginate.
  Future<({List<dynamic> items, Map<String, dynamic>? meta})> getPage(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final response = await _raw(path, 'GET', query: query);
    final body = _envelope(response);
    return (
      items: (body['data'] as List<dynamic>? ?? const []),
      meta: body['meta'] as Map<String, dynamic>?,
    );
  }

  Future<T> _send<T>(
    String path,
    String method, {
    Object? body,
    Map<String, dynamic>? query,
    T Function(dynamic data)? parse,
    bool skipAuth = false,
  }) async {
    final response = await _raw(
      path,
      method,
      body: body,
      query: query,
      skipAuth: skipAuth,
    );
    final data = _envelope(response)['data'];
    return parse != null ? parse(data) : data as T;
  }

  Future<Response<dynamic>> _raw(
    String path,
    String method, {
    Object? body,
    Map<String, dynamic>? query,
    bool skipAuth = false,
    bool isRetry = false,
  }) async {
    late final Response<dynamic> response;
    try {
      response = await _dio.request<dynamic>(
        path,
        data: body,
        queryParameters: query,
        options: Options(method: method, extra: {'skipAuth': skipAuth}),
      );
    } on DioException catch (e) {
      final wrapped = e.error;
      throw wrapped is ApiException ? wrapped : ApiException.network('$e');
    }

    // An expired access token is routine — 15-minute lifetime — so one
    // transparent refresh and retry is the expected path, not an error.
    if (response.statusCode == 401 && !skipAuth && !isRetry) {
      final code = _codeOf(response);
      if (code == ApiErrorCode.invalidToken) {
        final refreshed = await _refreshOnce();
        if (refreshed != null) {
          return _raw(
            path,
            method,
            body: body,
            query: query,
            skipAuth: skipAuth,
            isRetry: true,
          );
        }
      }
    }
    return response;
  }

  /// Refreshes at most once concurrently; callers await the same future.
  Future<TokenPair?> _refreshOnce() {
    return _refreshing ??= _performRefresh().whenComplete(() {
      _refreshing = null;
    });
  }

  Future<TokenPair?> _performRefresh() async {
    final current = await _tokens.read();
    if (current == null) return null;

    try {
      final data = await _send<Map<String, dynamic>>(
        '/auth/refresh',
        'POST',
        body: {'refresh_token': current.refreshToken},
        // Refreshing with the expired access token attached would 401 in a loop.
        skipAuth: true,
        parse: (d) => d as Map<String, dynamic>,
      );

      final pair = TokenPair(
        accessToken: data['access_token'] as String,
        refreshToken: data['refresh_token'] as String,
      );
      // Stored before it is used anywhere: the old one is already dead, so
      // losing the new one here would strand the session.
      await _tokens.write(pair);
      return pair;
    } on ApiException catch (e) {
      // Reuse, expiry, or revocation — none are recoverable on the client.
      await _tokens.clear();
      if (!_sessionLost.isClosed) _sessionLost.add(e);
      return null;
    }
  }

  static String? _codeOf(Response<dynamic> response) {
    final body = response.data;
    if (body is Map && body['error'] is Map) {
      return body['error']['code'] as String?;
    }
    return null;
  }

  /// Unwraps a success envelope, or throws the failure one.
  Map<String, dynamic> _envelope(Response<dynamic> response) {
    final body = response.data;
    final requestId = response.headers.value('x-request-id');

    if (body is! Map<String, dynamic>) {
      // A proxy error page or an HTML 502 — never the documented shape.
      throw ApiException(
        code: ApiErrorCode.network,
        message: 'Unexpected response from the server',
        statusCode: response.statusCode,
        requestId: requestId,
      );
    }

    if (body['success'] == true) return body;

    final error = body['error'];
    if (error is Map<String, dynamic>) {
      throw ApiException(
        code: error['code'] as String? ?? ApiErrorCode.network,
        message: error['message'] as String? ?? 'Something went wrong',
        details: error['details'] as Map<String, dynamic>?,
        statusCode: response.statusCode,
        requestId: requestId,
      );
    }

    throw ApiException(
      code: ApiErrorCode.network,
      message: 'Something went wrong',
      statusCode: response.statusCode,
      requestId: requestId,
    );
  }

  /// Closes the session-lost stream. Called by the composition root.
  Future<void> dispose() => _sessionLost.close();
}
