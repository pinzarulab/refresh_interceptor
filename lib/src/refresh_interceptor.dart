import 'dart:async';
import 'dart:collection';

import 'package:dio/dio.dart';

import 'refresh_init.dart';
import 'types.dart';

const _retriedKey = 'refresh_interceptor.retried';

enum _RefreshStatus { success, rejected, failed, stale }

final class _SessionSnapshot {
  const _SessionSnapshot({
    required this.generation,
    required this.accessToken,
    required this.refreshToken,
  });

  final int generation;
  final String? accessToken;
  final String? refreshToken;
}

final class _RefreshResult {
  const _RefreshResult(this.status, this.session);

  final _RefreshStatus status;
  final _SessionSnapshot session;
}

/// Shared token-refresh manager for one or more Dio clients.
///
/// Create one instance per authenticated session, then call [attachTo] for
/// every authenticated Dio client. All attached clients share one in-flight
/// refresh operation and one session-expiry notification.
final class RefreshInterceptor {
  RefreshInterceptor({
    required this.readAccessToken,
    required this.readRefreshToken,
    required this.saveTokens,
    required this.clearTokens,
    required this.onRefresh,
    SessionExpiredCallback? onSessionExpired,
    this.shouldRefresh = _defaultShouldRefresh,
    this.shouldAttachToken = _alwaysAttach,
    this.authorizationHeader = 'Authorization',
    this.tokenPrefix = 'Bearer',
    this.rejectIfTokenMissing = false,
    this.expireSessionOnMissingToken = false,
    this.clearTokensOnRefreshFailure = true,
    this.onError,
  }) : onSessionExpired =
            onSessionExpired ?? RefreshInit.instance.showSessionExpired;

  final ReadTokenCallback readAccessToken;
  final ReadTokenCallback readRefreshToken;
  final SaveTokensCallback saveTokens;
  final ClearTokensCallback clearTokens;
  final RefreshTokenCallback onRefresh;
  final SessionExpiredCallback onSessionExpired;
  final RefreshErrorPredicate shouldRefresh;
  final RequestPredicate shouldAttachToken;
  final String authorizationHeader;
  final String tokenPrefix;
  final bool rejectIfTokenMissing;
  final bool expireSessionOnMissingToken;
  final bool clearTokensOnRefreshFailure;

  /// Receives transient refresh, storage, and session callback errors.
  ///
  /// Exceptions thrown by this observer are ignored.
  final RefreshInterceptorErrorCallback? onError;

  final Map<Dio, Interceptor> _attached = HashMap<Dio, Interceptor>.identity();
  Future<_RefreshResult>? _refreshFuture;
  int? _refreshGeneration;
  bool _sessionExpiredNotified = false;
  String? _expiredAccessToken;
  int _sessionGeneration = 0;

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
  Future<bool> refreshAccessToken() async {
    final result = await _refreshOnce();
    return result.status == _RefreshStatus.success;
  }

  /// Starts a new session lifecycle explicitly.
  ///
  /// Call this before replacing tokens during login, logout, or account
  /// switching. It invalidates refresh operations started by the old session.
  /// A different token observed on a later request also resets expiry state.
  void resetSession() {
    _sessionGeneration++;
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

  void _reportError(Object error, StackTrace stack) {
    try {
      onError?.call(error, stack);
    } catch (_) {
      // Error reporting must never interrupt Dio's interceptor handlers.
    }
  }

  bool _shouldAttachToken(RequestOptions options) {
    try {
      return shouldAttachToken(options);
    } catch (error, stack) {
      _reportError(error, stack);
      return false;
    }
  }

  bool _shouldRefresh(DioException error) {
    try {
      return shouldRefresh(error);
    } catch (predicateError, stack) {
      _reportError(predicateError, stack);
      return false;
    }
  }

  Future<_SessionSnapshot> _captureSession() async {
    while (true) {
      final generation = _sessionGeneration;
      final accessToken = await readAccessToken();
      final refreshToken = await readRefreshToken();
      if (generation == _sessionGeneration) {
        return _SessionSnapshot(
          generation: generation,
          accessToken: accessToken,
          refreshToken: refreshToken,
        );
      }
    }
  }

  Future<bool> _isCurrentSession(_SessionSnapshot expected) async {
    if (expected.generation != _sessionGeneration) return false;
    final current = await _captureSession();
    return current.generation == expected.generation &&
        current.accessToken == expected.accessToken &&
        current.refreshToken == expected.refreshToken;
  }

  Future<_RefreshResult> _refreshOnce() {
    final active = _refreshFuture;
    if (active != null && _refreshGeneration == _sessionGeneration) {
      return active;
    }

    final operation = _performRefresh();
    _refreshFuture = operation;
    _refreshGeneration = _sessionGeneration;
    operation.whenComplete(() {
      if (identical(_refreshFuture, operation)) {
        _refreshFuture = null;
        _refreshGeneration = null;
      }
    });
    return operation;
  }

  Future<_RefreshResult> _performRefresh() async {
    _SessionSnapshot? session;
    try {
      session = await _captureSession();
      final storedRefreshToken = session.refreshToken;
      if (storedRefreshToken == null || storedRefreshToken.isEmpty) {
        return _RefreshResult(_RefreshStatus.rejected, session);
      }

      final tokens = await onRefresh(storedRefreshToken);
      if (tokens == null || tokens.accessToken.isEmpty) {
        return _RefreshResult(_RefreshStatus.rejected, session);
      }

      if (!await _isCurrentSession(session)) {
        return _RefreshResult(_RefreshStatus.stale, session);
      }

      await saveTokens(tokens.accessToken, tokens.refreshToken);
      resetSession();
      return _RefreshResult(_RefreshStatus.success, session);
    } catch (error, stack) {
      if (error is DioException && _shouldRefresh(error)) {
        session ??= _SessionSnapshot(
          generation: _sessionGeneration,
          accessToken: null,
          refreshToken: null,
        );
        return _RefreshResult(_RefreshStatus.rejected, session);
      }

      _reportError(error, stack);
      session ??= _SessionSnapshot(
        generation: _sessionGeneration,
        accessToken: null,
        refreshToken: null,
      );
      return _RefreshResult(_RefreshStatus.failed, session);
    }
  }

  Future<void> _expireSession(_SessionSnapshot session) async {
    if (_sessionExpiredNotified) return;
    try {
      if (!await _isCurrentSession(session)) return;
    } catch (error, stack) {
      _reportError(error, stack);
      return;
    }
    if (_sessionExpiredNotified) return;

    _sessionExpiredNotified = true;
    _expiredAccessToken = session.accessToken;

    if (clearTokensOnRefreshFailure) {
      try {
        await clearTokens();
      } catch (error, stack) {
        _reportError(error, stack);
      }
    }

    try {
      await onSessionExpired();
    } catch (error, stack) {
      _reportError(error, stack);
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
    if (!owner._shouldAttachToken(options)) {
      handler.next(options);
      return;
    }

    try {
      final accessToken = await owner.readAccessToken();
      if (accessToken == null || accessToken.isEmpty) {
        if (!owner.rejectIfTokenMissing) {
          handler.next(options);
          return;
        }

        final session = await owner._captureSession();
        final latestAccessToken = session.accessToken;
        if (latestAccessToken != null && latestAccessToken.isNotEmpty) {
          owner._observeAccessToken(latestAccessToken);
          options.headers[owner.authorizationHeader] =
              owner._authorizationValue(latestAccessToken);
          handler.next(options);
          return;
        }

        if (owner.expireSessionOnMissingToken) {
          await owner._expireSession(session);
        }
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
      owner._reportError(error, stack);
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
    if (!owner._shouldAttachToken(options) ||
        !owner._shouldRefresh(err) ||
        options.extra[_retriedKey] == true) {
      handler.next(err);
      return;
    }

    try {
      final session = await owner._captureSession();
      final currentToken = session.accessToken;
      final requestAuthorization = options.headers[owner.authorizationHeader];

      // Another request or Dio client refreshed while this response traveled.
      if (currentToken != null &&
          currentToken.isNotEmpty &&
          requestAuthorization != owner._authorizationValue(currentToken)) {
        await _retry(err, currentToken, handler);
        return;
      }

      final refresh = await owner._refreshOnce();
      final latestSession = await owner._captureSession();
      final latestToken = latestSession.accessToken;
      final tokenChanged = latestToken != null &&
          latestToken.isNotEmpty &&
          requestAuthorization != owner._authorizationValue(latestToken);

      if (latestToken != null &&
          latestToken.isNotEmpty &&
          (refresh.status == _RefreshStatus.success || tokenChanged)) {
        await _retry(err, latestToken, handler);
        return;
      }

      if (refresh.status == _RefreshStatus.rejected) {
        await owner._expireSession(refresh.session);
      }
      handler.next(err);
    } catch (error, stack) {
      owner._reportError(error, stack);
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
      if (owner._shouldRefresh(retryError)) {
        try {
          final session = await owner._captureSession();
          if (session.accessToken == accessToken) {
            await owner._expireSession(session);
          }
        } catch (error, stack) {
          owner._reportError(error, stack);
        }
      }
      handler.next(retryError);
    } catch (error, stack) {
      owner._reportError(error, stack);
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
