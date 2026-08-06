import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:refresh_interceptor/refresh_interceptor.dart';
import 'package:test/test.dart';

void main() {
  group('DioRefreshInterceptor', () {
    test('attaches the configured authorization header', () async {
      final store = MemoryTokenStore('access', 'refresh');
      final adapter = RecordingAdapter((options) => _json({'ok': true}, 200));
      final dio = Dio()..httpClientAdapter = adapter;
      dio.interceptors.add(
        DioRefreshInterceptor(
          dio: dio,
          tokenStore: store,
          tokenPrefix: 'Token',
          refreshToken: (_) async => null,
          onSessionExpired: () async {},
        ),
      );

      await dio.get<void>('/protected');

      expect(adapter.requests.single.headers['Authorization'], 'Token access');
    });

    test('concurrent failures share one refresh and all retry', () async {
      final store = MemoryTokenStore('old-access', 'old-refresh');
      var refreshCalls = 0;
      final adapter = RecordingAdapter((options) {
        final token = options.headers['Authorization'];
        return token == 'Bearer new-access'
            ? _json({'ok': true}, 200)
            : _json({'code': 'token_expired'}, 401);
      });
      final dio = Dio()..httpClientAdapter = adapter;
      dio.interceptors.add(
        DioRefreshInterceptor(
          dio: dio,
          tokenStore: store,
          refreshToken: (_) async {
            refreshCalls++;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return const RefreshTokens(
              accessToken: 'new-access',
              refreshToken: 'new-refresh',
            );
          },
          onSessionExpired: () async {},
        ),
      );

      final responses = await Future.wait([
        dio.get<Map<String, dynamic>>('/one'),
        dio.get<Map<String, dynamic>>('/two'),
        dio.get<Map<String, dynamic>>('/three'),
      ]);

      expect(responses, hasLength(3));
      expect(refreshCalls, 1);
      expect(store.accessToken, 'new-access');
      expect(store.refreshToken, 'new-refresh');
      expect(adapter.requests, hasLength(6));
    });

    test(
      'preserves stored refresh token when server does not rotate it',
      () async {
        final store = MemoryTokenStore('old', 'keep-me');
        final adapter = RecordingAdapter(
          (options) => options.headers['Authorization'] == 'Bearer new'
              ? _json({'ok': true}, 200)
              : _json({}, 401),
        );
        final dio = Dio()..httpClientAdapter = adapter;
        dio.interceptors.add(
          DioRefreshInterceptor(
            dio: dio,
            tokenStore: store,
            refreshToken: (_) async => const RefreshTokens(accessToken: 'new'),
            onSessionExpired: () async {},
          ),
        );

        await dio.get<void>('/protected');

        expect(store.refreshToken, 'keep-me');
      },
    );

    test('failed refresh clears tokens and expires session once', () async {
      final store = MemoryTokenStore('old', 'bad-refresh');
      var expiredCalls = 0;
      var refreshCalls = 0;
      final adapter = RecordingAdapter((_) => _json({}, 401));
      final dio = Dio()..httpClientAdapter = adapter;
      dio.interceptors.add(
        DioRefreshInterceptor(
          dio: dio,
          tokenStore: store,
          refreshToken: (_) async {
            refreshCalls++;
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return null;
          },
          onSessionExpired: () async => expiredCalls++,
        ),
      );

      final results = await Future.wait([
        dio
            .get<void>('/one')
            .then<Object>((value) => value)
            .catchError((Object e) => e),
        dio
            .get<void>('/two')
            .then<Object>((value) => value)
            .catchError((Object e) => e),
      ]);

      expect(results, everyElement(isA<DioException>()));
      expect(refreshCalls, 1);
      expect(expiredCalls, 1);
      expect(store.accessToken, isNull);
      expect(store.refreshToken, isNull);
    });

    test('never refreshes a retried request twice', () async {
      final store = MemoryTokenStore('old', 'refresh');
      var refreshCalls = 0;
      final dio = Dio()
        ..httpClientAdapter = RecordingAdapter((_) => _json({}, 401));
      dio.interceptors.add(
        DioRefreshInterceptor(
          dio: dio,
          tokenStore: store,
          refreshToken: (_) async {
            refreshCalls++;
            return const RefreshTokens(accessToken: 'still-invalid');
          },
          onSessionExpired: () async {},
        ),
      );

      await expectLater(
        dio.get<void>('/protected'),
        throwsA(isA<DioException>()),
      );
      expect(refreshCalls, 1);
    });
  });
}

final class MemoryTokenStore implements TokenStore {
  MemoryTokenStore(this.accessToken, this.refreshToken);

  String? accessToken;
  String? refreshToken;

  @override
  Future<String?> readAccessToken() async => accessToken;

  @override
  Future<String?> readRefreshToken() async => refreshToken;

  @override
  Future<void> saveTokens({
    required String accessToken,
    String? refreshToken,
  }) async {
    this.accessToken = accessToken;
    if (refreshToken != null) this.refreshToken = refreshToken;
  }

  @override
  Future<void> clearTokens() async {
    accessToken = null;
    refreshToken = null;
  }
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
