import 'dart:async';

import 'package:dio/dio.dart';

/// Tokens returned by the app's refresh request.
final class RefreshTokens {
  const RefreshTokens({required this.accessToken, this.refreshToken});

  final String accessToken;
  final String? refreshToken;
}

/// Performs the app-specific refresh request.
///
/// Return null only when the server permanently rejects the refresh token.
/// Throw for transient failures such as timeouts and server errors; transient
/// failures are reported through [RefreshInterceptorErrorCallback] without
/// clearing tokens or expiring the session.
typedef RefreshTokenCallback = Future<RefreshTokens?> Function(
    String refreshToken);

/// Runs once when the current session is permanently expired.
typedef SessionExpiredCallback = FutureOr<void> Function();

/// Decides whether a failed request requires authentication recovery.
typedef RefreshErrorPredicate = bool Function(DioException error);

/// Decides whether a request belongs to the authenticated session.
typedef RequestPredicate = bool Function(RequestOptions options);

/// Observes transient refresh, token storage, and callback errors.
///
/// Throwing from this callback is ignored so it cannot interrupt a request.
typedef RefreshInterceptorErrorCallback = void Function(
  Object error,
  StackTrace stack,
);
