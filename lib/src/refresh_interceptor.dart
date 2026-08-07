import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';

import 'token_store.dart';
import 'types.dart';

const _retriedKey = 'refresh_interceptor.retried';

/// Shared token-refresh manager for one or more Dio clients.
///
/// Create one instance per authenticated session, then call [attachTo] for
/// every authenticated Dio client. All attached clients share one in-flight
/// refresh operation and one session-expiry notification.
final class RefreshInterceptor {
  RefreshInterceptor({
    required this.tokenStore,
    required this.onRefresh,
    required this.onSessionExpired,
    this.shouldRefresh = _defaultShouldRefresh,
    this.shouldAttachToken = _alwaysAttach,
    this.authorizationHeader = 'Authorization',
    this.tokenPrefix = 'Bearer',
    this.rejectIfTokenMissing = false,
    this.clearTokensOnRefreshFailure = true,
    this.onError,
  });

  final TokenStore tokenStore;
  final RefreshTokenCallback onRefresh;
  final SessionExpiredCallback onSessionExpired;
  final RefreshErrorPredicate shouldRefresh;
  final RequestPredicate shouldAttachToken;
  final String authorizationHeader;
  final String tokenPrefix;
  final bool rejectIfTokenMissing;
  final bool clearTokensOnRefreshFailure;

  /// Receives refresh, storage, and session callback errors.
  final RefreshInterceptorErrorCallback? onError;

  final Map<Dio, Interceptor> _attached = HashMap<Dio, Interceptor>.identity();
  Future<bool>? _refreshFuture;
  bool _sessionExpiredNotified = false;
  String? _expiredAccessToken;

  /// Adds this refresh manager to [dio]. Calling this twice for the same Dio is
  /// safe; only one bound interceptor is installed.
  void attachTo(Dio dio) {
    if (_attached.containsKey(dio)) return;
    final interceptor = _BoundRefreshInterceptor(dio: dio, owner: this);
    _attached[dio] = interceptor;
    dio.interceptors.add(interceptor);
  }

  /// Adds this refresh manager to every Dio client in [clients].
  void attachToAll(Iterable<Dio> clients) {
    for (final dio in clients) {
      attachTo(dio);
    }
  }

  /// Removes this manager's bound interceptor from [dio].
  void detachFrom(Dio dio) {
    final interceptor = _attached.remove(dio);
    if (interceptor != null) dio.interceptors.remove(interceptor);
  }

  /// Starts a proactive refresh or joins the refresh currently in flight.
  ///
  /// Returns false without expiring the session. Callers decide how proactive
  /// refresh failure affects their UI.
  Future<bool> refreshAccessToken() => _refreshOnce();

  /// Starts a new session lifecycle explicitly.
  ///
  /// Usually unnecessary: seeing a token different from the expired token
  /// resets expiry state automatically.
  void resetSession() {
    _sessionExpiredNotified = false;
    _expiredAccessToken = null;
  }

  static bool _defaultShouldRefresh(DioException error) =>
      error.response?.statusCode == 401;

  static bool _alwaysAttach(RequestOptions _) => true;

  String _authorizationValue(String token) {
    if (tokenPrefix.isEmpty) return token;
    return '$tokenPrefix $token';
  }

  void _observeAccessToken(String token) {
    if (_sessionExpiredNotified && token != _expiredAccessToken) {
      resetSession();
    }
  }

  Future<bool> _refreshOnce() {
    final active = _refreshFuture;
    if (active != null) return active;

    final operation = _performRefresh();
    _refreshFuture = operation;
    operation.whenComplete(() {
      if (identical(_refreshFuture, operation)) {
        _refreshFuture = null;
      }
    });
    return operation;
  }

  Future<bool> _performRefresh() async {
    try {
      final storedRefreshToken = await tokenStore.readRefreshToken();
      if (storedRefreshToken == null || storedRefreshToken.isEmpty) {
        return false;
      }

      final tokens = await onRefresh(storedRefreshToken);
      if (tokens == null || tokens.accessToken.isEmpty) return false;

      await tokenStore.saveTokens(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
      );
      resetSession();
      return true;
    } catch (error, stack) {
      onError?.call(error, stack);
      return false;
    }
  }

  Future<void> _expireSession(String? accessToken) async {
    if (_sessionExpiredNotified) return;
    _sessionExpiredNotified = true;
    _expiredAccessToken = accessToken;

    if (clearTokensOnRefreshFailure) {
      try {
        await tokenStore.clearTokens();
      } catch (error, stack) {
        onError?.call(error, stack);
      }
    }

    try {
      await onSessionExpired();
    } catch (error, stack) {
      onError?.call(error, stack);
    }
  }
}

final class _BoundRefreshInterceptor extends Interceptor {
  _BoundRefreshInterceptor({required this.dio, required this.owner});

  final Dio dio;
  final RefreshInterceptor owner;

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (!owner.shouldAttachToken(options)) {
      handler.next(options);
      return;
    }

    try {
      final accessToken = await owner.tokenStore.readAccessToken();
      if (accessToken == null || accessToken.isEmpty) {
        if (!owner.rejectIfTokenMissing) {
          handler.next(options);
          return;
        }

        await owner._expireSession(null);
        handler.reject(
          DioException(
            requestOptions: options,
            response: Response<void>(requestOptions: options, statusCode: 401),
            error: const {'reason': 'no_token'},
            type: DioExceptionType.badResponse,
          ),
        );
        return;
      }

      owner._observeAccessToken(accessToken);
      options.headers[owner.authorizationHeader] =
          owner._authorizationValue(accessToken);
      handler.next(options);
    } catch (error, stack) {
      owner.onError?.call(error, stack);
      handler.reject(
        DioException(
          requestOptions: options,
          error: error,
          stackTrace: stack,
          type: DioExceptionType.unknown,
        ),
      );
    }
  }

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) async {
    final options = err.requestOptions;
    if (!owner.shouldRefresh(err) || options.extra[_retriedKey] == true) {
      handler.next(err);
      return;
    }

    String? currentToken;
    try {
      currentToken = await owner.tokenStore.readAccessToken();
      final requestAuthorization = options.headers[owner.authorizationHeader];

      // Another request or Dio client refreshed while this response traveled.
      if (currentToken != null &&
          requestAuthorization != owner._authorizationValue(currentToken)) {
        await _retry(err, currentToken, handler);
        return;
      }

      final refreshed = await owner._refreshOnce();
      if (refreshed) {
        final newToken = await owner.tokenStore.readAccessToken();
        if (newToken != null && newToken.isNotEmpty) {
          await _retry(err, newToken, handler);
          return;
        }
      }

      await owner._expireSession(currentToken);
      handler.next(err);
    } catch (error, stack) {
      owner.onError?.call(error, stack);
      await owner._expireSession(currentToken);
      handler.next(err);
    }
  }

  Future<void> _retry(
    DioException originalError,
    String accessToken,
    ErrorInterceptorHandler handler,
  ) async {
    final options = originalError.requestOptions;
    options.extra[_retriedKey] = true;
    options.headers[owner.authorizationHeader] =
        owner._authorizationValue(accessToken);

    try {
      final response = await dio.fetch<dynamic>(options);
      handler.resolve(response);
    } on DioException catch (retryError) {
      if (owner.shouldRefresh(retryError)) {
        await owner._expireSession(accessToken);
      }
      handler.next(retryError);
    } catch (error, stack) {
      owner.onError?.call(error, stack);
      handler.next(
        DioException(
          requestOptions: options,
          error: error,
          stackTrace: stack,
          type: DioExceptionType.unknown,
        ),
      );
    }
  }
}
