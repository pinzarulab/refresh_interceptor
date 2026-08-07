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
/// Return null when refresh is rejected. Throwing also counts as failure.
typedef RefreshTokenCallback = Future<RefreshTokens?> Function(
    String refreshToken);

typedef SessionExpiredCallback = FutureOr<void> Function();
typedef RefreshErrorPredicate = bool Function(DioException error);
typedef RequestPredicate = bool Function(RequestOptions options);
typedef RefreshInterceptorErrorCallback = void Function(
  Object error,
  StackTrace stack,
);
