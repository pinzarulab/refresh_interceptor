# refresh_interceptor

Reusable token refresh interceptor for Dio. It removes app-specific dependencies
from auth retry logic while keeping storage, endpoint shape, and logout behavior
under app control.

## Features

- Adds access token to outgoing requests.
- Runs only one refresh for concurrent expired requests.
- Retries each failed request once with newest token.
- Supports refresh-token rotation.
- Prevents refresh loops.
- Supports custom expiry rules, auth schemes, public routes, and session cleanup.
- Has no service-locator or state-management dependency.

## Setup

Implement `TokenStore` using secure storage or your existing local data source:

```dart
final class AppTokenStore implements TokenStore {
  @override
  Future<String?> readAccessToken() => storage.read(key: 'access');

  @override
  Future<String?> readRefreshToken() => storage.read(key: 'refresh');

  @override
  Future<void> saveTokens({
    required String accessToken,
    String? refreshToken,
  }) async {
    await storage.write(key: 'access', value: accessToken);
    if (refreshToken != null) {
      await storage.write(key: 'refresh', value: refreshToken);
    }
  }

  @override
  Future<void> clearTokens() => storage.deleteAll();
}
```

Use a separate Dio instance for refresh calls. This avoids the refresh request
passing through the same interceptor:

```dart
final apiDio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
final refreshDio = Dio(BaseOptions(baseUrl: 'https://api.example.com'));
final tokenStore = AppTokenStore();

final authInterceptor = DioRefreshInterceptor(
  dio: apiDio,
  tokenStore: tokenStore,
  refreshToken: (refreshToken) async {
    final response = await refreshDio.post<Map<String, dynamic>>(
      '/authorization/token/refresh/',
      data: {'refresh': refreshToken},
    );
    final data = response.data!;
    return RefreshTokens(
      accessToken: data['access'] as String,
      refreshToken: data['refresh'] as String?,
    );
  },
  onSessionExpired: () async {
    // Reset app state or navigate to login.
  },
);

apiDio.interceptors.add(authInterceptor);
```

Default auth header is `Authorization: Bearer <token>`. For another scheme:

```dart
DioRefreshInterceptor(
  // ...
  tokenPrefix: 'Token',
);
```

Customize protected routes and expiry response detection:

```dart
DioRefreshInterceptor(
  // ...
  shouldAttachToken: (request) => !request.path.startsWith('/public/'),
  shouldRefresh: (error) {
    final data = error.response?.data;
    return error.response?.statusCode == 401 ||
        data is Map && data['code'] == 'token_expired';
  },
  rejectIfTokenMissing: true,
);
```

Call `authInterceptor.resetSession()` after a new login if the same interceptor
instance survives logout and login.

## Retry note

Dio request bodies backed by one-shot streams cannot always be replayed. Buffer
upload data when requests must survive token refresh.

See `example/` for a runnable Flutter app with an in-memory fake API.

