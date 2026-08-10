import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:refresh_interceptor/refresh_interceptor.dart';
import 'package:test/test.dart';

void main() {
  group('RefreshInterceptor', () {
    test('attaches with one call and never attaches twice', () async {
      final store = MemoryTokenStore('access', 'refresh');
      final adapter = RecordingAdapter((_) => _json({'ok': true}, 200));
      final dio = Dio()..httpClientAdapter = adapter;
      final initialInterceptorCount = dio.interceptors.length;
      final auth = RefreshInterceptor(
        tokenStore: store,
        tokenPrefix: 'Token',
        onRefresh: (_) async => null,
        onSessionExpired: () {},
      );

      auth.attachTo(dio);
      auth.attachTo(dio);
      await dio.get<void>('/protected');

      expect(dio.interceptors, hasLength(initialInterceptorCount + 1));
      expect(adapter.requests.single.headers['Authorization'], 'Token access');
    });

    test('all attached Dio clients share one refresh', () async {
      final store = MemoryTokenStore('old-access', 'old-refresh');
      var refreshCalls = 0;
      final firstAdapter = RecordingAdapter(_requiresNewToken);
      final secondAdapter = RecordingAdapter(_requiresNewToken);
      final firstDio = Dio()..httpClientAdapter = firstAdapter;
      final secondDio = Dio()..httpClientAdapter = secondAdapter;
      final auth = RefreshInterceptor(
        tokenStore: store,
        onRefresh: (_) async {
          refreshCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return const RefreshTokens(
            accessToken: 'new-access',
            refreshToken: 'new-refresh',
          );
        },
        onSessionExpired: () {},
      );
      auth.attachToAll([firstDio, secondDio]);

      final responses = await Future.wait([
        firstDio.get<Map<String, dynamic>>('/one'),
        secondDio.get<Map<String, dynamic>>('/two'),
        firstDio.get<Map<String, dynamic>>('/three'),
      ]);

      expect(responses, hasLength(3));
      expect(refreshCalls, 1);
      expect(store.accessToken, 'new-access');
      expect(store.refreshToken, 'new-refresh');
      expect(firstAdapter.requests, hasLength(4));
      expect(secondAdapter.requests, hasLength(2));
    });

    test(
      'preserves stored refresh token when server does not rotate it',
      () async {
        final store = MemoryTokenStore('old', 'keep-me');
        final dio = Dio()
          ..httpClientAdapter = RecordingAdapter(
            (options) => options.headers['Authorization'] == 'Bearer new'
                ? _json({'ok': true}, 200)
                : _json({}, 401),
          );
        RefreshInterceptor(
          tokenStore: store,
          onRefresh: (_) async => const RefreshTokens(accessToken: 'new'),
          onSessionExpired: () {},
        ).attachTo(dio);

        await dio.get<void>('/protected');

        expect(store.refreshToken, 'keep-me');
      },
    );

    test('failed refresh expires session once across Dio clients', () async {
      final store = MemoryTokenStore('old', 'bad-refresh');
      var expiredCalls = 0;
      var refreshCalls = 0;
      final firstDio = Dio()
        ..httpClientAdapter = RecordingAdapter((_) => _json({}, 401));
      final secondDio = Dio()
        ..httpClientAdapter = RecordingAdapter((_) => _json({}, 401));
      final auth = RefreshInterceptor(
        tokenStore: store,
        onRefresh: (_) async {
          refreshCalls++;
          await Future<void>.delayed(const Duration(milliseconds: 20));
          return null;
        },
        onSessionExpired: () => expiredCalls++,
      );
      auth.attachToAll([firstDio, secondDio]);

      final results = await Future.wait([
        _captureError(firstDio.get<void>('/one')),
        _captureError(secondDio.get<void>('/two')),
      ]);

      expect(results, everyElement(isA<DioException>()));
      expect(refreshCalls, 1);
      expect(expiredCalls, 1);
      expect(store.accessToken, isNull);
      expect(store.refreshToken, isNull);
    });

    test('transient refresh errors do not clear or expire the session',
        () async {
      final store = MemoryTokenStore('old-access', 'refresh');
      final reportedErrors = <Object>[];
      var expiredCalls = 0;
      final dio = Dio()
        ..httpClientAdapter = RecordingAdapter((_) => _json({}, 401));
      RefreshInterceptor(
        tokenStore: store,
        onRefresh: (_) async => throw StateError('network unavailable'),
        onSessionExpired: () => expiredCalls++,
        onError: (error, _) => reportedErrors.add(error),
      ).attachTo(dio);

      final error = await _captureError(dio.get<void>('/protected'));

      expect(error, isA<DioException>());
      expect((error as DioException).response?.statusCode, 401);
      expect(expiredCalls, 0);
      expect(store.accessToken, 'old-access');
      expect(store.refreshToken, 'refresh');
      expect(reportedErrors.single, isA<StateError>());
    });

    test('excluded requests never refresh or expire the session', () async {
      final store = MemoryTokenStore('access', 'refresh');
      var refreshCalls = 0;
      var expiredCalls = 0;
      final dio = Dio()
        ..httpClientAdapter = RecordingAdapter((_) => _json({}, 401));
      RefreshInterceptor(
        tokenStore: store,
        shouldAttachToken: (request) => !request.path.startsWith('/public'),
        onRefresh: (_) async {
          refreshCalls++;
          return null;
        },
        onSessionExpired: () => expiredCalls++,
      ).attachTo(dio);

      await _captureError(dio.get<void>('/public/info'));

      expect(refreshCalls, 0);
      expect(expiredCalls, 0);
      expect(store.accessToken, 'access');
    });

    test('a token appearing during a missing-token check is preserved',
        () async {
      final store = LoginDuringReadTokenStore();
      var expiredCalls = 0;
      final dio = Dio()
        ..httpClientAdapter = RecordingAdapter(
          (options) => options.headers['Authorization'] == 'Bearer new-access'
              ? _json({'ok': true}, 200)
              : _json({}, 401),
        );
      RefreshInterceptor(
        tokenStore: store,
        rejectIfTokenMissing: true,
        onRefresh: (_) async => null,
        onSessionExpired: () => expiredCalls++,
      ).attachTo(dio);

      await dio.get<void>('/protected');

      expect(expiredCalls, 0);
      expect(store.clearCalls, 0);
    });

    test('an old refresh cannot overwrite a reset session', () async {
      final store = MemoryTokenStore('old-access', 'old-refresh');
      final refreshStarted = Completer<void>();
      final finishRefresh = Completer<RefreshTokens?>();
      var expiredCalls = 0;
      final dio = Dio()
        ..httpClientAdapter = RecordingAdapter(
          (options) => options.headers['Authorization'] == 'Bearer login-access'
              ? _json({'ok': true}, 200)
              : _json({}, 401),
        );
      final auth = RefreshInterceptor(
        tokenStore: store,
        onRefresh: (_) {
          refreshStarted.complete();
          return finishRefresh.future;
        },
        onSessionExpired: () => expiredCalls++,
      )..attachTo(dio);

      final request = dio.get<void>('/protected');
      await refreshStarted.future;
      auth.resetSession();
      store
        ..accessToken = 'login-access'
        ..refreshToken = 'login-refresh';
      finishRefresh.complete(
        const RefreshTokens(
          accessToken: 'stale-access',
          refreshToken: 'stale-refresh',
        ),
      );

      await request;
      expect(store.accessToken, 'login-access');
      expect(store.refreshToken, 'login-refresh');
      expect(expiredCalls, 0);
    });

    test('throwing predicates and error reporters cannot strand requests',
        () async {
      final store = MemoryTokenStore('access', 'refresh');
      final dio = Dio()
        ..httpClientAdapter = RecordingAdapter((_) => _json({}, 401));
      RefreshInterceptor(
        tokenStore: store,
        shouldRefresh: (_) => throw StateError('predicate failed'),
        onRefresh: (_) async => null,
        onSessionExpired: () {},
        onError: (_, __) => throw StateError('reporter failed'),
      ).attachTo(dio);

      final error = await _captureError(
        dio.get<void>('/protected').timeout(const Duration(seconds: 1)),
      );

      expect(error, isA<DioException>());
      expect(store.accessToken, 'access');
    });

    test('a different login token starts a new session automatically',
        () async {
      final store = MemoryTokenStore('first-access', 'first-refresh');
      var expiredCalls = 0;
      final dio = Dio()
        ..httpClientAdapter = RecordingAdapter((_) => _json({}, 401));
      final auth = RefreshInterceptor(
        tokenStore: store,
        onRefresh: (_) async => null,
        onSessionExpired: () => expiredCalls++,
      );
      auth.attachTo(dio);

      await _captureError(dio.get<void>('/first-session'));
      store
        ..accessToken = 'second-access'
        ..refreshToken = 'second-refresh';
      await _captureError(dio.get<void>('/second-session'));

      expect(expiredCalls, 2);
    });

    test('non-auth retry error does not expire a refreshed session', () async {
      final store = MemoryTokenStore('old', 'refresh');
      var expiredCalls = 0;
      final dio = Dio()
        ..httpClientAdapter = RecordingAdapter(
          (options) => options.headers['Authorization'] == 'Bearer new'
              ? _json({'error': 'server'}, 500)
              : _json({}, 401),
        );
      RefreshInterceptor(
        tokenStore: store,
        onRefresh: (_) async => const RefreshTokens(accessToken: 'new'),
        onSessionExpired: () => expiredCalls++,
      ).attachTo(dio);

      final error = await _captureError(dio.get<void>('/protected'));

      expect(error, isA<DioException>());
      expect((error as DioException).response?.statusCode, 500);
      expect(expiredCalls, 0);
      expect(store.accessToken, 'new');
    });

    test('never refreshes a retried request twice', () async {
      final store = MemoryTokenStore('old', 'refresh');
      var refreshCalls = 0;
      var expiredCalls = 0;
      final dio = Dio()
        ..httpClientAdapter = RecordingAdapter((_) => _json({}, 401));
      RefreshInterceptor(
        tokenStore: store,
        onRefresh: (_) async {
          refreshCalls++;
          return const RefreshTokens(accessToken: 'still-invalid');
        },
        onSessionExpired: () => expiredCalls++,
      ).attachTo(dio);

      await expectLater(
        dio.get<void>('/protected'),
        throwsA(isA<DioException>()),
      );
      expect(refreshCalls, 1);
      expect(expiredCalls, 1);
    });

    test('TokenStoreAdapter accepts existing method tear-offs', () async {
      final existing = MemoryTokenStore('access', 'refresh');
      final adapter = TokenStoreAdapter(
        readAccessToken: existing.readAccessToken,
        readRefreshToken: existing.readRefreshToken,
        saveTokens: existing.updateTokens,
        clearTokens: existing.clearTokens,
      );

      await adapter.saveTokens(
        accessToken: 'new-access',
        refreshToken: 'new-refresh',
      );

      expect(await adapter.readAccessToken(), 'new-access');
      expect(await adapter.readRefreshToken(), 'new-refresh');
    });
  });
}

ResponseBody _requiresNewToken(RequestOptions options) =>
    options.headers['Authorization'] == 'Bearer new-access'
        ? _json({'ok': true}, 200)
        : _json({'code': 'token_expired'}, 401);

Future<Object> _captureError(Future<Object?> request) async {
  try {
    return (await request) ?? Object();
  } catch (error) {
    return error;
  }
}

final class MemoryTokenStore implements TokenStore {
  MemoryTokenStore(this.accessToken, this.refreshToken);

  String? accessToken;
  String? refreshToken;

  @override
  Future<String?> readAccessToken() async => accessToken;

  @override
  Future<String?> readRefreshToken() async => refreshToken;

  Future<void> updateTokens(String accessToken, String? refreshToken) async {
    this.accessToken = accessToken;
    if (refreshToken != null) this.refreshToken = refreshToken;
  }

  @override
  Future<void> saveTokens({
    required String accessToken,
    String? refreshToken,
  }) =>
      updateTokens(accessToken, refreshToken);

  @override
  Future<void> clearTokens() async {
    accessToken = null;
    refreshToken = null;
  }
}

final class LoginDuringReadTokenStore implements TokenStore {
  var _accessReads = 0;
  var clearCalls = 0;

  @override
  Future<String?> readAccessToken() async =>
      _accessReads++ == 0 ? null : 'new-access';

  @override
  Future<String?> readRefreshToken() async => 'new-refresh';

  @override
  Future<void> saveTokens({
    required String accessToken,
    String? refreshToken,
  }) async {}

  @override
  Future<void> clearTokens() async => clearCalls++;
}

final class RecordingAdapter implements HttpClientAdapter {
  RecordingAdapter(this.responseFor);

  final ResponseBody Function(RequestOptions options) responseFor;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options.copyWith(headers: Map.of(options.headers)));
    return responseFor(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object data, int statusCode) => ResponseBody.fromString(
      jsonEncode(data),
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
