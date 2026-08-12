import 'dart:async';

import 'package:dio/dio.dart';

/// Reads one token from app storage.
///
/// Both synchronous and asynchronous storage implementations are supported.
typedef ReadTokenCallback = FutureOr<String?> Function();

/// Stores refreshed tokens. A null refresh token means "keep current token".
///
/// Implementations must finish persistence before completing so retried
/// requests observe the new access token.
typedef SaveTokensCallback = FutureOr<void> Function(
  String accessToken,
  String? refreshToken,
);

/// Removes all locally stored authentication tokens.
///
/// Both synchronous and asynchronous storage implementations are supported.
typedef ClearTokensCallback = FutureOr<void> Function();

/// Tokens returned by the app's refresh request.
final class RefreshTokens {
  /// Creates the successful result of a refresh request.
  ///
  /// Omit [refreshToken] when the server does not rotate refresh tokens.
  const RefreshTokens({required this.accessToken, this.refreshToken});

  /// New non-empty access token used for retried requests.
  final String accessToken;

  /// Rotated refresh token, or null to keep the currently stored token.
  final String? refreshToken;
}

/// Performs the app-specific refresh request.
///
/// Return null only when the server permanently rejects the refresh token.
/// A thrown [DioException] matching the interceptor's refresh predicate is
/// also treated as a permanent rejection.
/// Throw for transient failures such as timeouts and server errors; transient
/// failures are reported through [RefreshInterceptorErrorCallback] without
/// clearing tokens or expiring the session.
typedef RefreshTokenCallback = Future<RefreshTokens?> Function(
    String refreshToken);

/// Runs once when the current session is permanently expired.
///
/// May clear application state or navigate to login. Concurrent failures from
/// clients attached to one interceptor produce one callback per session.
typedef SessionExpiredCallback = FutureOr<void> Function();

/// Decides whether a failed request requires authentication recovery.
///
/// The default predicate matches HTTP 401. Predicate exceptions are reported
/// through [RefreshInterceptorErrorCallback] and treated as false.
typedef RefreshErrorPredicate = bool Function(DioException error);

/// Decides whether a request belongs to the authenticated session.
///
/// Return false for login, refresh, public, or third-party requests. Predicate
/// exceptions are reported through [RefreshInterceptorErrorCallback] and the
/// request receives no authentication handling.
typedef RequestPredicate = bool Function(RequestOptions options);

/// Observes transient refresh, token storage, and callback errors.
///
/// Throwing from this callback is ignored so it cannot interrupt a request.
typedef RefreshInterceptorErrorCallback = void Function(
  Object error,
  StackTrace stack,
);
