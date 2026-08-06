/// Storage contract used by [DioRefreshInterceptor].
///
/// Implement this with secure storage, a database, or any app-specific token
/// repository. `saveTokens` receives a nullable refresh token because not every
/// server rotates refresh tokens. A null value means "keep the current one".
abstract interface class TokenStore {
  Future<String?> readAccessToken();

  Future<String?> readRefreshToken();

  Future<void> saveTokens({required String accessToken, String? refreshToken});

  Future<void> clearTokens();
}
