import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nimbus_drive/core/network/api_client.dart';
import 'package:nimbus_drive/core/network/api_exception.dart';
import 'package:nimbus_drive/core/network/token_store.dart';

/// Answers from a script instead of a socket.
class _StubAdapter implements HttpClientAdapter {
  _StubAdapter(this.handler);

  final ResponseBody Function(RequestOptions options) handler;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<List<int>>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return handler(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(String body, int status) => ResponseBody.fromString(
  body,
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

ResponseBody _ok(String data) => _json('{"success":true,"data":$data}', 200);

ResponseBody _fail(String code, int status) => _json(
  '{"success":false,"error":{"code":"$code","message":"nope"}}',
  status,
);

({ApiClient client, _StubAdapter adapter, InMemoryTokenStore tokens}) _build(
  ResponseBody Function(RequestOptions) handler,
) {
  final tokens = InMemoryTokenStore();
  final adapter = _StubAdapter(handler);
  final dio = Dio(
    BaseOptions(baseUrl: 'http://test/api', validateStatus: (_) => true),
  )..httpClientAdapter = adapter;

  return (
    client: ApiClient(tokens, dio: dio),
    adapter: adapter,
    tokens: tokens,
  );
}

void main() {
  test('unwraps the success envelope', () async {
    final h = _build((_) => _ok('{"name":"file.pdf"}'));
    final data = await h.client.get<Map<String, dynamic>>(
      '/files/1',
      parse: (d) => d as Map<String, dynamic>,
    );

    expect(data['name'], 'file.pdf');
  });

  test('throws the failure envelope with its code intact', () async {
    final h = _build((_) => _fail(ApiErrorCode.fileNotFound, 404));

    await expectLater(
      h.client.get<dynamic>('/files/missing'),
      throwsA(
        isA<ApiException>().having(
          (e) => e.code,
          'code',
          ApiErrorCode.fileNotFound,
        ),
      ),
    );
  });

  test('exposes 422 field errors as a map for forms', () async {
    final h = _build(
      (_) => _json(
        '{"success":false,"error":{"code":"VALIDATION_ERROR",'
        '"message":"bad","details":{"fields":[{"field":"email",'
        '"message":"not an email"}]}}}',
        422,
      ),
    );

    try {
      await h.client.post<dynamic>('/auth/register', body: {});
      fail('should have thrown');
    } on ApiException catch (e) {
      expect(e.fieldErrors['email'], 'not an email');
    }
  });

  test('attaches the bearer token, except where told not to', () async {
    final h = _build((_) => _ok('{}'));
    await h.tokens.write(
      const TokenPair(accessToken: 'access-1', refreshToken: 'refresh-1'),
    );

    await h.client.get<dynamic>('/auth/me');
    await h.client.post<dynamic>('/auth/login', skipAuth: true);

    expect(h.adapter.requests[0].headers['Authorization'], 'Bearer access-1');
    expect(h.adapter.requests[1].headers.containsKey('Authorization'), isFalse);
  });

  test('refreshes once on INVALID_TOKEN and replays the request', () async {
    var meCalls = 0;

    final h = _build((options) {
      if (options.path == '/auth/refresh') {
        return _ok('{"access_token":"access-2","refresh_token":"refresh-2"}');
      }
      meCalls++;
      // Only the first attempt sees the expired token.
      return meCalls == 1
          ? _fail(ApiErrorCode.invalidToken, 401)
          : _ok('{"email":"a@b.com"}');
    });

    await h.tokens.write(
      const TokenPair(accessToken: 'stale', refreshToken: 'refresh-1'),
    );

    final data = await h.client.get<Map<String, dynamic>>(
      '/auth/me',
      parse: (d) => d as Map<String, dynamic>,
    );

    expect(data['email'], 'a@b.com');
    expect(meCalls, 2, reason: 'the original request must be retried once');
    expect((await h.tokens.read())!.accessToken, 'access-2');
  });

  test('concurrent 401s share one refresh', () async {
    var refreshCalls = 0;
    final seen = <String>{};

    final h = _build((options) {
      if (options.path == '/auth/refresh') {
        refreshCalls++;
        return _ok('{"access_token":"access-2","refresh_token":"refresh-2"}');
      }
      // Each endpoint 401s once, then succeeds.
      if (seen.add(options.path)) return _fail(ApiErrorCode.invalidToken, 401);
      return _ok('{}');
    });

    await h.tokens.write(
      const TokenPair(accessToken: 'stale', refreshToken: 'refresh-1'),
    );

    await Future.wait([
      h.client.get<dynamic>('/files'),
      h.client.get<dynamic>('/folders'),
      h.client.get<dynamic>('/shares'),
    ]);

    // Refresh tokens are single-use: a second concurrent refresh would consume
    // an already-spent token and trip TOKEN_REUSE_DETECTED for no reason.
    expect(refreshCalls, 1);
  });

  test('a failed refresh clears tokens and reports the session lost', () async {
    final h = _build((options) {
      if (options.path == '/auth/refresh') {
        return _fail(ApiErrorCode.tokenReuseDetected, 401);
      }
      return _fail(ApiErrorCode.invalidToken, 401);
    });

    await h.tokens.write(
      const TokenPair(accessToken: 'stale', refreshToken: 'replayed'),
    );

    final lost = h.client.onSessionLost.first;
    await h.client.get<dynamic>('/files').catchError((Object _) => null);

    final event = await lost;
    expect(event.requiresReauth, isTrue);
    expect(
      await h.tokens.read(),
      isNull,
      reason: 'dead tokens must not linger',
    );
  });

  test('does not retry a 401 that is not about the token', () async {
    var calls = 0;
    final h = _build((_) {
      calls++;
      return _fail(ApiErrorCode.invalidCredentials, 401);
    });

    await expectLater(
      h.client.post<dynamic>('/auth/login', skipAuth: true),
      throwsA(isA<ApiException>()),
    );
    expect(calls, 1);
  });

  test('a non-envelope body becomes a network error, not a crash', () async {
    final h = _build(
      (_) => ResponseBody.fromString('<html>502</html>', 502, headers: {}),
    );

    await expectLater(
      h.client.get<dynamic>('/files'),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', ApiErrorCode.network),
      ),
    );
  });
}
