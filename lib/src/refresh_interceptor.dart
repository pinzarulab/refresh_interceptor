import 'dart:async';

import 'package:dio/dio.dart';

import 'token_store.dart';
import 'types.dart';

const _retriedKey = 'refresh_interceptor.retried';

/// Dio interceptor that attaches access tokens and refreshes expired sessions.
///
/// Concurrent 401 responses share one refresh operation. Requests that failed
/// with an already-stale access token reuse the token produced by that operation
/// instead of starting another refresh.
final class DioRefreshInterceptor extends Interceptor {
  DioRefreshInterceptor({
    required this.dio,
    required this.tokenStore,
    required this.refreshToken,
    required this.onSessionExpired,
    this.shouldRefresh = _defaultShouldRefresh,
    this.shouldAttachToken = _alwaysAttach,
    this.authorizationHeader = 'Authorization',
    this.tokenPrefix = 'Bearer',
    this.rejectIfTokenMissing = false,
    this.clearTokensOnRefreshFailure = true,
    this.onRefreshFailure,
  });

  final Dio dio;
  final TokenStore tokenStore;
  final RefreshTokenCallback refreshToken;
  final SessionExpiredCallback onSessionExpired;
  final RefreshErrorPredicate shouldRefresh;
  final RequestPredicate shouldAttachToken;
  final String authorizationHeader;
  final String tokenPrefix;
  final bool rejectIfTokenMissing;
  final bool clearTokensOnRefreshFailure;
  final RefreshFailureCallback? onRefreshFailure;

  Future<bool>? _refreshFuture;
  bool _sessionExpiredNotified = false;

  /// Starts a refresh or joins the refresh currently in flight.
  ///
  /// This can be used for proactive refresh. Intercepted responses call it
  /// automatically. It returns false without expiring the session; callers of
  /// this method decide how proactive-refresh failure should affect the UI.
  Future<bool> refreshAccessToken() => _refreshOnce();

  static bool _defaultShouldRefresh(DioException error) =>
      error.response?.statusCode == 401;

  static bool _alwaysAttach(RequestOptions _) => true;

  String _authorizationValue(String token) {
    if (tokenPrefix.isEmpty) return token;
    return '$tokenPrefix $token';
  }

  @override
  void onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (!shouldAttachToken(options)) {
      handler.next(options);
      return;
    }

    try {
      final accessToken = await tokenStore.readAccessToken();
      if (accessToken == null || accessToken.isEmpty) {
        if (!rejectIfTokenMissing) {
          handler.next(options);
          return;
        }

        await _notifySessionExpired();
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

      options.headers[authorizationHeader] = _authorizationValue(accessToken);
      handler.next(options);
    } catch (error, stack) {
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
    if (!shouldRefresh(err) || options.extra[_retriedKey] == true) {
      handler.next(err);
      return;
    }

    try {
      final currentToken = await tokenStore.readAccessToken();
      final requestAuthorization = options.headers[authorizationHeader];

      // Another request may already have refreshed while this response traveled.
      if (currentToken != null &&
          requestAuthorization != _authorizationValue(currentToken)) {
        await _retry(err, currentToken, handler);
        return;
      }

      final refreshed = await _refreshOnce();
      if (refreshed) {
        final newToken = await tokenStore.readAccessToken();
        if (newToken != null && newToken.isNotEmpty) {
          await _retry(err, newToken, handler);
          return;
        }
      }

      if (clearTokensOnRefreshFailure) await tokenStore.clearTokens();
      await _notifySessionExpired();
      handler.next(err);
    } catch (refreshError, stack) {
      onRefreshFailure?.call(refreshError, stack);
      if (clearTokensOnRefreshFailure) {
        try {
          await tokenStore.clearTokens();
        } catch (clearError, clearStack) {
          onRefreshFailure?.call(clearError, clearStack);
        }
      }
      await _notifySessionExpired();
      handler.next(err);
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

      final tokens = await refreshToken(storedRefreshToken);
      if (tokens == null || tokens.accessToken.isEmpty) return false;

      await tokenStore.saveTokens(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
      );
      _sessionExpiredNotified = false;
      return true;
    } catch (error, stack) {
      onRefreshFailure?.call(error, stack);
      return false;
    }
  }

  Future<void> _retry(
    DioException error,
    String accessToken,
    ErrorInterceptorHandler handler,
  ) async {
    final options = error.requestOptions;
    options.extra[_retriedKey] = true;
    options.headers[authorizationHeader] = _authorizationValue(accessToken);
    final response = await dio.fetch<dynamic>(options);
    handler.resolve(response);
  }

  Future<void> _notifySessionExpired() async {
    if (_sessionExpiredNotified) return;
    _sessionExpiredNotified = true;
    await onSessionExpired();
  }

  /// Allows a newly authenticated session to emit future expiry callbacks.
  void resetSession() => _sessionExpiredNotified = false;
}
