import 'dart:async';

/// Storage contract used by [RefreshInterceptor].
///
/// Implement this with secure storage, a database, or use [TokenStoreAdapter]
/// to connect existing methods without creating another class.
abstract interface class TokenStore {
  Future<String?> readAccessToken();

  Future<String?> readRefreshToken();

  /// Saves new tokens. A null refresh token means "keep the current one".
  Future<void> saveTokens({required String accessToken, String? refreshToken});

  Future<void> clearTokens();
}

typedef ReadToken = FutureOr<String?> Function();
typedef SaveTokens = FutureOr<void> Function(
  String accessToken,
  String? refreshToken,
);
typedef ClearTokens = FutureOr<void> Function();

/// Connects existing token methods to [TokenStore] with function tear-offs.
final class TokenStoreAdapter implements TokenStore {
  const TokenStoreAdapter({
    required ReadToken readAccessToken,
    required ReadToken readRefreshToken,
    required SaveTokens saveTokens,
    required ClearTokens clearTokens,
  })  : _readAccessToken = readAccessToken,
        _readRefreshToken = readRefreshToken,
        _saveTokens = saveTokens,
        _clearTokens = clearTokens;

  final ReadToken _readAccessToken;
  final ReadToken _readRefreshToken;
  final SaveTokens _saveTokens;
  final ClearTokens _clearTokens;

  @override
  Future<String?> readAccessToken() async => _readAccessToken();

  @override
  Future<String?> readRefreshToken() async => _readRefreshToken();

  @override
  Future<void> saveTokens({
    required String accessToken,
    String? refreshToken,
  }) async {
    await _saveTokens(accessToken, refreshToken);
  }

  @override
  Future<void> clearTokens() async => _clearTokens();
}
